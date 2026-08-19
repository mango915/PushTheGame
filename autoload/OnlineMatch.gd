extends Node

# For developers to set from the outside, for example:
#   OnlineMatch.max_players = 8
#   OnlineMatch.client_version = 'v1.2'
var min_players := 2
var max_players := 4
var client_version := 'dev'

var nakama_multiplayer_bridge: NakamaMultiplayerBridge

# Nakama variables:
#
# NOTE: these used to be declared with `set = _set_readonly_variable` -- a setter
# with an empty body -- to make them read-only from outside this class. GDScript
# setters also intercept writes from *inside* the class, so every assignment
# below was silently discarded: match_state never left LOBBY, leave() never
# cleared the player list, and the matchmaker ticket was never recorded. Only
# in-place mutation (players[id] = ...) worked, which is why this half-functioned.
# They are plain vars now; treat them as read-only from outside.
var match_id: String: get = get_match_id
var matchmaker_ticket: String
var nakama_socket: NakamaSocket: set = _set_nakama_socket

var players: Dictionary

# Short, human-readable room code for host/join. Nakama match ids are UUIDs,
# which nobody can read out loud; a named match gives us a code instead.
var room_code: String = ''

enum MatchState {
	LOBBY = 0,
	MATCHING = 1,
	CONNECTING = 2,
	WAITING_FOR_ENOUGH_PLAYERS = 3,
	READY = 4,
	PLAYING = 5,
}
var match_state: int = MatchState.LOBBY: get = get_match_state

enum MatchMode {
	NONE = 0,
	CREATE = 1,
	JOIN = 2,
	MATCHMAKER = 3,
	# Serverless play over a local network (see autoload/LanMatch.gd). The
	# transport is a plain ENetMultiplayerPeer instead of the Nakama bridge;
	# everything above this class is peer-id based and cannot tell the
	# difference.
	LAN_HOST = 4,
	LAN_JOIN = 5,
	# Play over Steam's own networking (see autoload/SteamMatch.gd). Same deal
	# as LAN: a MultiplayerPeer replaces the Nakama bridge and nothing above
	# this class notices. Only available when the GodotSteam GDExtension is
	# installed -- see docs/steam.md.
	STEAM_HOST = 6,
	STEAM_JOIN = 7,
}
var match_mode: int = MatchMode.NONE: get = get_match_mode

# There is no match id on a LAN -- there is no server to mint one -- but the
# lobby wants something to show. Same on Steam, where the "id" is a 64-bit
# lobby number nobody wants to read out loud.
const LAN_MATCH_ID := 'LAN'
const STEAM_MATCH_ID := 'STEAM'

# match_joined must be emitted exactly once per match; on the peer transports
# (LAN and Steam) it can be triggered either by connected_to_server or by
# peer_connected(1), whichever the engine delivers first.
var _peer_match_joined_emitted := false

signal error (message)
signal disconnected ()

signal match_joined (match_id, mode)

signal player_joined (player)
signal player_left (player)
# An already-known player's details changed (their character arrived, say).
signal player_updated (player)

signal match_ready (players)
signal match_not_ready ()

class Player:
	var session_id: String
	var peer_id: int
	var username: String
	# Index into Player.PlayerSkin -- which character this player chose.
	var character: int = 0

	func _init(_session_id: String, _username: String, _peer_id: int, _character: int = 0) -> void:
		session_id = _session_id
		username = _username
		peer_id = _peer_id
		character = _character

	static func from_presence(presence: NakamaRTAPI.UserPresence, _peer_id: int) -> Player:
		return Player.new(presence.session_id, presence.username, _peer_id)

	static func from_dict(data: Dictionary) -> Player:
		return Player.new(data['session_id'], data['username'], int(data['peer_id']),
			int(data.get('character', 0)))

	# Players on a peer transport (LAN, Steam) have no Nakama presence: there is
	# no server that issued them a session id, and nobody knows their name until
	# they announce it over the wire. The session id is synthesised from the
	# peer id, which is the only identity such a match actually has.
	static func from_peer(_prefix: String, _peer_id: int, _username: String, _character: int = 0) -> Player:
		var name := _username.strip_edges()
		if name == '':
			name = 'Player %d' % _peer_id
		return Player.new('%s-%d' % [_prefix, _peer_id], name, _peer_id, _character)

	static func from_lan(_peer_id: int, _username: String, _character: int = 0) -> Player:
		return Player.from_peer('lan', _peer_id, _username, _character)

	static func from_steam(_peer_id: int, _username: String, _character: int = 0) -> Player:
		return Player.from_peer('steam', _peer_id, _username, _character)

	func to_dict() -> Dictionary:
		return {
			session_id = session_id,
			username = username,
			peer_id = peer_id,
			character = character,
		}

static func serialize_players(_players: Dictionary) -> Dictionary:
	var result := {}
	for key in _players:
		result[key] = _players[key].to_dict()
	return result

static func unserialize_players(_players: Dictionary) -> Dictionary:
	var result := {}
	for key in _players:
		result[key] = Player.from_dict(_players[key])
	return result

func _set_nakama_socket(_nakama_socket: NakamaSocket) -> void:

	if nakama_socket == _nakama_socket:
		return

	if nakama_socket:
		nakama_socket.closed.disconnect(Callable(self, "_on_nakama_socket_closed"))

	if nakama_multiplayer_bridge:
		nakama_multiplayer_bridge.match_joined.disconnect(Callable(self, "_on_match_joined"))
		nakama_multiplayer_bridge.match_join_error.disconnect(Callable(self, "_on_match_join_error"))
		nakama_multiplayer_bridge.leave()
		nakama_multiplayer_bridge = null
		get_tree().get_multiplayer().multiplayer_peer = null

	nakama_socket = _nakama_socket

	if nakama_socket:
		nakama_socket.closed.connect(Callable(self, "_on_nakama_socket_closed"))
		nakama_multiplayer_bridge = NakamaMultiplayerBridge.new(nakama_socket)
		nakama_multiplayer_bridge.match_joined.connect(Callable(self, "_on_match_joined"))
		nakama_multiplayer_bridge.match_join_error.connect(Callable(self, "_on_match_join_error"))
		get_tree().get_multiplayer().set_multiplayer_peer(nakama_multiplayer_bridge.multiplayer_peer)

func _ready() -> void:
	var tree = get_tree()
	tree.get_multiplayer().peer_connected.connect(Callable(self, "_on_network_peer_connected"))
	tree.get_multiplayer().peer_disconnected.connect(Callable(self, "_on_network_peer_disconnected"))

	# Only meaningful for the LAN transport: joining a Nakama match resolves
	# through the bridge's own match_joined/match_join_error signals instead.
	# The handlers below all bail out unless a LAN match is in progress.
	tree.get_multiplayer().connected_to_server.connect(Callable(self, "_on_lan_connected_to_server"))
	tree.get_multiplayer().connection_failed.connect(Callable(self, "_on_lan_connection_failed"))
	tree.get_multiplayer().server_disconnected.connect(Callable(self, "_on_lan_server_disconnected"))

	# Autoloads are readied in registration order and SteamMatch is registered
	# after this one, so its node does not exist yet at this point. Deferring
	# the hookup also keeps this class working in a scene where the Steam
	# autoload is absent entirely.
	call_deferred("_connect_steam_match")

#####
# Steam play (friends, invites, Steam's own networking -- see SteamMatch)
#####

# The Steam autoload, or null when it is not registered. Every Steam call in
# this class goes through here so that OnlineMatch never hard-depends on it.
func _steam_match() -> Node:
	return get_node_or_null("/root/SteamMatch")

func _connect_steam_match() -> void:
	var steam_match := _steam_match()
	if steam_match == null:
		return
	# invite_accepted means the player already said yes (in the Steam overlay or
	# from their friends list), so joining is the correct response to it.
	if not steam_match.invite_accepted.is_connected(Callable(self, "_on_steam_invite_accepted")):
		steam_match.invite_accepted.connect(Callable(self, "_on_steam_invite_accepted"))
	if not steam_match.lobby_ready.is_connected(Callable(self, "_on_steam_lobby_ready")):
		steam_match.lobby_ready.connect(Callable(self, "_on_steam_lobby_ready"))
	if not steam_match.steam_error.is_connected(Callable(self, "_on_steam_error")):
		steam_match.steam_error.connect(Callable(self, "_on_steam_error"))

# True while a host/join call is on the stack. A failure raised synchronously
# from SteamMatch is reported by the returning call itself, so the steam_error
# handler must not report it a second time.
var _steam_call_in_progress := false

func is_steam() -> bool:
	return match_mode == MatchMode.STEAM_HOST or match_mode == MatchMode.STEAM_JOIN

# LAN and Steam are both "a MultiplayerPeer and nothing else": no presence list,
# no server-issued session ids, names and characters announced peer to peer.
func is_peer_transport() -> bool:
	return is_lan() or is_steam()

func steam_is_available() -> bool:
	var steam_match := _steam_match()
	if steam_match == null:
		return false
	return steam_match.is_available()

# Creates a Steam lobby and hosts on it. Returns false immediately (and emits
# `error`) when Steam is unavailable; otherwise the match is not actually joined
# until SteamMatch reports the lobby is up, which is why this looks less
# synchronous than host_lan_match().
func host_steam_match(friends_only: bool = true) -> bool:
	leave()

	var steam_match := _steam_match()
	if steam_match == null:
		emit_signal("error", "Steam support is not installed")
		return false

	match_mode = MatchMode.STEAM_HOST
	match_state = MatchState.CONNECTING

	_steam_call_in_progress = true
	var started: bool = steam_match.host_lobby(friends_only, max_players)
	_steam_call_in_progress = false

	if not started:
		match_mode = MatchMode.NONE
		match_state = MatchState.LOBBY
		emit_signal("error", steam_match.last_error if steam_match.last_error != '' else "Could not host on Steam")
		return false

	return true

# Joins a Steam lobby by id -- which the player never types: it arrives from an
# invite or from the friends list.
func join_steam_match(lobby_id: int) -> bool:
	leave()

	var steam_match := _steam_match()
	if steam_match == null:
		emit_signal("error", "Steam support is not installed")
		return false

	match_mode = MatchMode.STEAM_JOIN
	match_state = MatchState.CONNECTING

	_steam_call_in_progress = true
	var started: bool = steam_match.join_lobby(lobby_id)
	_steam_call_in_progress = false

	if not started:
		match_mode = MatchMode.NONE
		match_state = MatchState.LOBBY
		emit_signal("error", steam_match.last_error if steam_match.last_error != '' else "Could not join that Steam game")
		return false

	return true

func _on_steam_invite_accepted(lobby_id: int, _friend_steam_id: int) -> void:
	join_steam_match(lobby_id)

# The lobby exists and the transport is installed. The host is peer 1 from that
# moment, so it registers itself and announces the match exactly as a LAN host
# does; a client waits for connected_to_server instead.
func _on_steam_lobby_ready(_lobby_id: int) -> void:
	if not is_steam():
		return
	if match_mode != MatchMode.STEAM_HOST:
		return
	_ensure_local_peer_player()
	_emit_peer_match_joined()
	_check_enough_players()

# A Steam failure that arrives after host/join returned true (lobby creation is
# asynchronous) still has to reach the player.
func _on_steam_error(message: String) -> void:
	if not is_steam() or _steam_call_in_progress:
		return
	leave()
	emit_signal("error", message)

#####
# LAN play (no server, no room code, no IP addresses -- see LanMatch)
#####

func is_lan() -> bool:
	return match_mode == MatchMode.LAN_HOST or match_mode == MatchMode.LAN_JOIN

# Starts hosting on the local network. Returns false (and emits `error`) if the
# port could not be opened.
func host_lan_match(port: int = -1) -> bool:
	leave()

	match_mode = MatchMode.LAN_HOST
	match_state = MatchState.CONNECTING

	if not LanMatch.host_lan(port if port > 0 else LanMatch.DEFAULT_GAME_PORT):
		match_mode = MatchMode.NONE
		match_state = MatchState.LOBBY
		emit_signal("error", LanMatch.last_error if LanMatch.last_error != '' else "Could not host on the local network")
		return false

	# The host is peer 1 the moment the server peer exists, so it can register
	# itself immediately -- there is no round trip to wait for.
	_ensure_local_peer_player()
	_emit_peer_match_joined()
	_check_enough_players()
	return true

# Connects to a host found by LanMatch.discover_hosts(). The match is not joined
# until the connection lands: match_joined is emitted from
# _on_lan_connected_to_server.
func join_lan_match(address: String, port: int = -1) -> bool:
	leave()

	match_mode = MatchMode.LAN_JOIN
	match_state = MatchState.CONNECTING

	if not LanMatch.join_lan(address, port if port > 0 else LanMatch.DEFAULT_GAME_PORT):
		match_mode = MatchMode.NONE
		match_state = MatchState.LOBBY
		emit_signal("error", LanMatch.last_error if LanMatch.last_error != '' else "Could not reach that game")
		return false

	return true

# Tell every other peer which character we just switched to, so their lobby
# updates without waiting for a reconnect.
func announce_local_character() -> void:
	if players.has(get_tree().get_multiplayer().get_unique_id()):
		players[get_tree().get_multiplayer().get_unique_id()].character = _local_character()
	if get_tree().get_multiplayer().multiplayer_peer == null:
		return
	if players.size() <= 1:
		return
	rpc("_lan_announce_player", _local_display_name(), _local_character())

func _local_character() -> int:
	return Online.character_index if Online else 0

func _local_display_name() -> String:
	return Online.display_name.strip_edges()

func _ensure_local_peer_player() -> void:
	var my_peer_id := get_tree().get_multiplayer().get_unique_id()
	if my_peer_id == 0 or players.has(my_peer_id):
		return
	players[my_peer_id] = _make_peer_player(my_peer_id, _local_display_name(), _local_character())

# One Player for whichever peer transport is in use. Steam and LAN differ only
# in the synthetic session id, which is never shown to anybody.
func _make_peer_player(peer_id: int, username: String, character: int = 0) -> Player:
	if is_steam():
		return Player.from_steam(peer_id, username, character)
	return Player.from_lan(peer_id, username, character)

func _emit_peer_match_joined() -> void:
	if _peer_match_joined_emitted:
		return
	_peer_match_joined_emitted = true
	emit_signal("match_joined", STEAM_MATCH_ID if is_steam() else LAN_MATCH_ID, match_mode)

func _on_lan_connected_to_server() -> void:
	if not is_peer_transport():
		return
	_ensure_local_peer_player()
	_emit_peer_match_joined()
	_check_enough_players()

func _on_lan_connection_failed() -> void:
	if not is_peer_transport():
		return
	leave()
	emit_signal("error", "Could not reach that game - is it still open?")

func _on_lan_server_disconnected() -> void:
	if not is_peer_transport():
		return
	leave()
	emit_signal("disconnected")

# Peers introduce themselves to each other on connect, because a LAN match has
# no presence list to look names up in. The Player is created here rather than
# in _on_network_peer_connected so the lobby never shows a placeholder name.
@rpc("any_peer", "call_remote", "reliable") func _lan_announce_player(username: String, character: int = 0) -> void:

	var peer_id := get_tree().get_multiplayer().get_remote_sender_id()
	if peer_id == 0:
		return

	var existing = players.get(peer_id)
	if existing != null:
		# A re-announcement only refreshes the name; the lobby already has them.
		# On Nakama the presence username is authoritative; on LAN the
		# announcement is the only source. Either way the character only ever
		# arrives this way.
		if is_peer_transport():
			existing.username = _make_peer_player(peer_id, username).username
		existing.character = character
		emit_signal("player_updated", existing)
		return

	var player := _make_peer_player(peer_id, username, character)
	players[peer_id] = player
	emit_signal("player_joined", player)

	_check_enough_players()

func create_match(_nakama_socket: NakamaSocket) -> void:
	leave()
	_set_nakama_socket(_nakama_socket)
	match_mode = MatchMode.CREATE

	nakama_multiplayer_bridge.create_match()

# Characters chosen to be unambiguous when read aloud or typed: no O/0, I/1,
# S/5, Z/2.
const ROOM_CODE_CHARS := 'ABCDEFGHJKLMNPQRTUVWXY346789'
const ROOM_CODE_LENGTH := 4

static func generate_room_code() -> String:
	var code := ''
	for i in range(ROOM_CODE_LENGTH):
		code += ROOM_CODE_CHARS[randi() % ROOM_CODE_CHARS.length()]
	return code

# Host a room under a short code. Nakama named matches are create-or-join, so
# this is the same call the joiner makes -- whoever arrives first becomes host.
func host_room(_nakama_socket: NakamaSocket, _room_code: String = '') -> String:
	leave()
	_set_nakama_socket(_nakama_socket)
	match_mode = MatchMode.CREATE
	room_code = _room_code.strip_edges().to_upper()
	if room_code == '':
		room_code = generate_room_code()

	nakama_multiplayer_bridge.join_named_match(room_code)
	return room_code

func join_room(_nakama_socket: NakamaSocket, _room_code: String) -> void:
	leave()
	_set_nakama_socket(_nakama_socket)
	match_mode = MatchMode.JOIN
	room_code = _room_code.strip_edges().to_upper()

	nakama_multiplayer_bridge.join_named_match(room_code)

func join_match(_nakama_socket: NakamaSocket, _match_id: String) -> void:
	leave()
	_set_nakama_socket(_nakama_socket)
	match_mode = MatchMode.JOIN

	nakama_multiplayer_bridge.join_match(_match_id)

func start_matchmaking(_nakama_socket: NakamaSocket, data: Dictionary = {}) -> void:
	#leave()

	_set_nakama_socket(_nakama_socket)
	match_mode = MatchMode.MATCHMAKER

	if data.has('min_count'):
		data['min_count'] = max(min_players, data['min_count'])
	else:
		data['min_count'] = min_players

	if data.has('max_count'):
		data['max_count'] = min(max_players, data['max_count'])
	else:
		data['max_count'] = max_players

	if client_version != '':
		if not data.has('string_properties'):
			data['string_properties'] = {}
		data['string_properties']['client_version'] = client_version

		var query = '+properties.client_version:' + client_version
		if data.has('query'):
			data['query'] += ' ' + query
		else:
			data['query'] = query

	match_state = MatchState.MATCHING
	var result = await nakama_socket.add_matchmaker_async(data.get('query', '*'), data['min_count'], data['max_count'], data.get('string_properties', {}), data.get('numeric_properties', {}))
	if result.is_exception():
		leave()
		emit_signal("error", "Unable to join match making pool")
	else:
		matchmaker_ticket = result.ticket
		nakama_multiplayer_bridge.start_matchmaking(result)

func start_playing() -> void:
	#assert(match_state == MatchState.READY)
	match_state = MatchState.PLAYING

func leave(close_socket: bool = false) -> void:
	# LAN disconnect. A no-op when no LAN game is running, so this is safe on
	# every path through leave() -- and it is what frees the ENet port and the
	# discovery socket, so hosting again in the same session works.
	LanMatch.stop_lan()
	# Steam disconnect, same deal: a no-op when no Steam lobby is open, and
	# reached through the node rather than the global so this class still works
	# with the Steam autoload absent.
	var steam_match := _steam_match()
	if steam_match != null:
		steam_match.leave()
	_peer_match_joined_emitted = false

	# Nakama disconnect. Guarded: on a LAN there is no socket and no bridge, and
	# calling into them would be a "Nonexistent function" on a null.
	if nakama_multiplayer_bridge:
		nakama_multiplayer_bridge.leave()
	if nakama_socket:
		if matchmaker_ticket:
			await nakama_socket.remove_matchmaker_async(matchmaker_ticket)
		if close_socket:
			nakama_socket.close()
			_set_nakama_socket(null)

	# Initialize all the variables to their default state.
	# (match_id is derived from the bridge -- see get_match_id.)
	players = {}
	room_code = ''
	matchmaker_ticket = ''
	match_state = MatchState.LOBBY
	match_mode = MatchMode.NONE

func get_match_id() -> String:
	if is_lan():
		return LAN_MATCH_ID
	if is_steam():
		return STEAM_MATCH_ID
	if nakama_multiplayer_bridge:
		return nakama_multiplayer_bridge.match_id
	return ''

func get_match_mode() -> int:
	return match_mode

func get_match_state() -> int:
	return match_state

func get_player_names_by_peer_id() -> Dictionary:
	var result = {}
	for peer_id in players:
		result[peer_id] = players[peer_id].username
	return result

func _on_nakama_socket_closed() -> void:
	leave()
	emit_signal("disconnected")

func _check_enough_players() -> void:
	if players.size() >= min_players:
		match_state = MatchState.READY
		emit_signal("match_ready", players)
	else:
		match_state = MatchState.WAITING_FOR_ENOUGH_PLAYERS
		emit_signal("match_not_ready")

func _on_match_joined() -> void:
	var my_peer_id = get_tree().get_multiplayer().get_unique_id()
	var presence: NakamaRTAPI.UserPresence = nakama_multiplayer_bridge.get_user_presence_for_peer(my_peer_id)
	var player = Player.from_presence(presence, my_peer_id)
	player.character = _local_character()
	players[my_peer_id] = player
	emit_signal("match_joined", nakama_multiplayer_bridge.match_id, match_mode)

# Connected in _set_nakama_socket. Without this, every failed create/join threw
# "Nonexistent function" instead of surfacing the error to the player.
func _on_match_join_error(exception) -> void:
	var message := "Unable to join match"
	if exception != null:
		message = str(exception)
	leave()
	emit_signal("error", message)

@rpc("authority", "call_remote", "reliable") func _boot_with_error(msg: String) -> void:
	leave()
	emit_signal("error", msg)

@rpc("authority", "call_remote", "reliable") func _check_client_version(host_client_version: String) -> void:
	if client_version != host_client_version:
		leave()
		emit_signal("error", "Client version doesn't match host")

func _on_network_peer_connected(peer_id: int) -> void:
	if is_multiplayer_authority():
		if match_state == MatchState.PLAYING:
			rpc_id(peer_id, "_boot_with_error", 'Sorry! The match has already begun.')
			return

		if players.size() >= max_players:
			rpc_id(peer_id, "_boot_with_error", "Sorry! The match is full.")
			return

		# Ask the client to check it's client version.
		rpc_id(peer_id, "_check_client_version", client_version)

	if is_peer_transport() or nakama_multiplayer_bridge == null:
		# No Nakama presence to look this peer up in: introduce ourselves and
		# wait for them to do the same. _lan_announce_player creates the Player
		# and emits player_joined when their name arrives.
		#
		# The null-bridge case is the same situation reached by a bare
		# multiplayer peer (a test harness, say); reading a presence off a null
		# bridge would be a hard runtime error, which is exactly what LAN play
		# used to hit here.
		if is_peer_transport():
			_ensure_local_peer_player()
			_emit_peer_match_joined()
		rpc_id(peer_id, "_lan_announce_player", _local_display_name(), _local_character())
		return

	var presence: NakamaRTAPI.UserPresence = nakama_multiplayer_bridge.get_user_presence_for_peer(peer_id)
	var player = Player.from_presence(presence, peer_id)
	players[peer_id] = player
	emit_signal("player_joined", player)

	# A Nakama presence carries a username but no chosen character, so peers
	# announce that to each other explicitly -- same message LAN uses.
	rpc_id(peer_id, "_lan_announce_player", _local_display_name(), _local_character())

	_check_enough_players()


func _on_network_peer_disconnected(peer_id: int) -> void:
	var player = players.get(peer_id)
	if player != null:
		emit_signal("player_left", player)
		players.erase(peer_id)

	_check_enough_players()
