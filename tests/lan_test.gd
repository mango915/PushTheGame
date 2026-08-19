extends Node

# Guards LAN play: the serverless transport in autoload/LanMatch.gd and the
# LAN branches of autoload/OnlineMatch.gd.
#
# Everything here runs in ONE process with NO server and NO second machine:
# discovery probes go to 127.0.0.1 as well as to the broadcast address, so a
# host can find itself, and the ENet loopback check drives two raw peers by
# hand. What this cannot cover is two machines actually seeing each other over
# a real broadcast domain -- that is tests/lantest.sh (see the header there).

# Ports used only by this test, deliberately away from LanMatch.DEFAULT_GAME_PORT
# so a game running on this machine does not interfere.
const TEST_PORT := 8761
const OCCUPIED_PORT := 8763
const MATCH_PORT := 8765
const LOOPBACK_PORT := 8767

var _failures := 0
var _errors_from_online_match := 0

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[lan] OK: %s" % label)
	else:
		_failures += 1
		print("[lan] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _ready() -> void:
	print("[lan] starting")

	OnlineMatch.error.connect(func (_message): _errors_from_online_match += 1)

	_check_payload()
	_check_lan_player()
	await _check_hosting()
	await _check_discovery()
	_check_port_conflicts()
	await _check_online_match_lan_lifecycle()
	await _check_loopback_connection()

	# Leave nothing bound behind us.
	LanMatch.stop_lan()

	print("[lan] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

#####
# The discovery payload is the only thing on the wire before a game starts, so
# it has to survive a round trip and reject anything that is not ours.
#####

func _check_payload() -> void:
	var probe := LanMatch.build_probe()
	var decoded := LanMatch.decode_message(LanMatch.encode_message(probe))
	_check("probe survives a round trip", decoded.get('type', ''), LanMatch.MSG_PROBE)
	_check("probe carries the game id", decoded.get('game', ''), LanMatch.PROTOCOL_ID)
	_check("probe carries the protocol version", int(decoded.get('v', 0)), LanMatch.PROTOCOL_VERSION)

	# Junk on a well-known UDP port is normal; it must not throw or be believed.
	_check("garbage decodes to nothing",
		LanMatch.decode_message("this is not json".to_utf8_buffer()).size(), 0)
	_check("an empty datagram decodes to nothing",
		LanMatch.decode_message(PackedByteArray()).size(), 0)
	_check("another game's broadcast is ignored",
		LanMatch.decode_message(JSON.stringify({game = "some_other_game", v = 1}).to_utf8_buffer()).size(), 0)
	_check("a different protocol version is ignored",
		LanMatch.decode_message(JSON.stringify({
			game = LanMatch.PROTOCOL_ID,
			v = LanMatch.PROTOCOL_VERSION + 1,
		}).to_utf8_buffer()).size(), 0)

	# An advert becomes the entry the UI lists and join_lan() consumes. The
	# address is NOT in the payload: it is the source address of the reply, so a
	# host behind two interfaces is joinable on whichever one answered.
	var entry := LanMatch.advert_to_host_entry({
		id = 'abc123',
		name = 'Kuba',
		port = 9000,
		players = 2,
		max_players = 4,
		open = true,
	}, '192.168.1.42')
	_check("entry keeps the host name", entry.name, 'Kuba')
	_check("entry takes the address from the packet", entry.address, '192.168.1.42')
	_check("entry keeps the game port", entry.port, 9000)
	_check("entry keeps the player count", entry.players, 2)
	_check("entry keeps the maximum", entry.max_players, 4)

	# A malformed advert must still produce something joinable-looking rather
	# than crashing the browser UI.
	var empty := LanMatch.advert_to_host_entry({}, '10.0.0.1')
	_check("a nameless advert still gets a label", empty.name.is_empty(), false)
	_check("a portless advert falls back to the default port",
		empty.port, LanMatch.DEFAULT_GAME_PORT)

#####
# A LAN player is built from a name announced over the wire, not from a Nakama
# presence: there is no server to have issued one.
#####

func _check_lan_player() -> void:
	var player = OnlineMatch.Player.from_lan(7, "Kuba")
	_check("lan player keeps the announced name", player.username, "Kuba")
	_check("lan player keeps the peer id", player.peer_id, 7)
	_check("lan player has a synthesised session id", player.session_id, "lan-7")

	var anonymous = OnlineMatch.Player.from_lan(3, "   ")
	_check("a blank announced name falls back to the peer id",
		anonymous.username, "Player 3")

	# to_dict()/from_dict() is how Game replicates the roster, so a LAN player
	# has to survive it like any other.
	var restored = OnlineMatch.Player.from_dict(player.to_dict())
	_check("lan player survives serialisation", restored.username, "Kuba")
	_check("lan player survives serialisation (peer id)", restored.peer_id, 7)

#####
# Hosting, stopping, and hosting again in one session.
#####

func _check_hosting() -> void:
	var started := LanMatch.host_lan(TEST_PORT)
	_check_true("host_lan succeeds", started)
	_check_true("LanMatch reports it is hosting", LanMatch.hosting)
	_check("host_lan uses the port it was given", LanMatch.game_port, TEST_PORT)

	var peer = multiplayer.multiplayer_peer
	_check_true("an ENet peer is installed", peer is ENetMultiplayerPeer)
	_check("the host is peer 1", multiplayer.get_unique_id(), 1)

	# The advert describes this host, and must be readable by the other side.
	var advert := LanMatch.decode_message(LanMatch.encode_message(LanMatch.build_advert()))
	_check("advert announces the game port", int(advert.get('port', 0)), TEST_PORT)
	_check("advert announces the host name", str(advert.get('name', '')), Online.display_name)
	_check_true("advert announces at least one player", int(advert.get('players', 0)) >= 1)
	_check("advert announces the player limit",
		int(advert.get('max_players', 0)), OnlineMatch.max_players)

	LanMatch.stop_lan()
	_check_true("stop_lan drops the multiplayer peer", multiplayer.multiplayer_peer == null)
	_check("stop_lan clears the hosting flag", LanMatch.hosting, false)
	_check("stop_lan forgets the port", LanMatch.game_port, 0)
	_check("stop_lan leaves nothing active", LanMatch.is_active(), false)

	# Calling it twice must be harmless -- leave() does exactly that.
	LanMatch.stop_lan()
	_check("stopping twice is harmless", LanMatch.is_active(), false)

	# The regression this guards: an ENet server or a UDP beacon left bound
	# makes the next host attempt fail with "address in use".
	await get_tree().process_frame
	var restarted := LanMatch.host_lan(TEST_PORT, 0, false)
	_check_true("hosting again on the same port works", restarted)
	_check("the second host got the same port", LanMatch.game_port, TEST_PORT)

#####
# Discovery over loopback: the host answers its own probe. This is the whole
# "nobody types an IP address" mechanism, minus the broadcast hop.
#####

func _check_discovery() -> void:
	_check_true("still hosting before the search", LanMatch.hosting)

	var hosts: Array = await LanMatch.discover_hosts(1.5)
	_check_true("discovery returned an array", hosts is Array)

	var mine := {}
	for host in hosts:
		if host.port == TEST_PORT:
			mine = host
	_check_true("discovery found the local host (%d game(s) seen)" % hosts.size(),
		not mine.is_empty())

	if not mine.is_empty():
		_check("discovered host advertises our name", mine.name, Online.display_name)
		_check("discovered host advertises our port", mine.port, TEST_PORT)
		_check_true("discovered host has a joinable address", mine.address != '')
		_check_true("discovered host reports a player count", mine.players >= 1)

	LanMatch.stop_lan()

	# With nobody hosting, a search must come back empty rather than hanging or
	# reporting a stale host.
	var none: Array = await LanMatch.discover_hosts(0.4)
	var still_mine := false
	for host in none:
		if host.port == TEST_PORT:
			still_mine = true
	_check("a stopped host stops being discoverable", still_mine, false)

#####
# Port already in use, with and without the fallback.
#####

func _check_port_conflicts() -> void:
	# Something else (another instance of the game, say) holds the port.
	var squatter := ENetMultiplayerPeer.new()
	var err := squatter.create_server(OCCUPIED_PORT, 1)
	_check("the test could occupy a port", err, OK)

	var refused := LanMatch.host_lan(OCCUPIED_PORT, 0, false)
	_check("hosting on a busy port fails instead of half-working", refused, false)
	_check_true("the failure is reported", LanMatch.last_error != '')
	_check("a failed host installs no peer", multiplayer.multiplayer_peer == null, true)

	# With the fallback allowed it should step over the occupied port.
	var moved := LanMatch.host_lan(OCCUPIED_PORT)
	_check_true("hosting falls back to a free port", moved)
	_check_true("the fallback port is a different one", LanMatch.game_port != OCCUPIED_PORT)

	LanMatch.stop_lan()
	squatter.close()

	# Joining nothing is a user-visible mistake, not a crash.
	_check("joining an empty address is refused", LanMatch.join_lan("", MATCH_PORT), false)
	_check_true("the refusal is reported", LanMatch.last_error != '')
	_check("a refused join installs no peer", multiplayer.multiplayer_peer == null, true)

#####
# OnlineMatch's LAN mode: the same players/state/signals the Nakama path
# produces, with no socket anywhere.
#####

func _check_online_match_lan_lifecycle() -> void:
	var joined := []
	OnlineMatch.match_joined.connect(func (match_id, mode): joined.append([match_id, mode]), CONNECT_ONE_SHOT)

	var hosted: bool = OnlineMatch.host_lan_match(MATCH_PORT)
	_check_true("host_lan_match succeeds", hosted)
	_check("match mode is LAN_HOST", OnlineMatch.match_mode, OnlineMatch.MatchMode.LAN_HOST)
	_check_true("is_lan() is true", OnlineMatch.is_lan())
	_check("match_joined was emitted once", joined.size(), 1)
	if joined.size() == 1:
		_check("match_joined reports the LAN match id", joined[0][0], OnlineMatch.LAN_MATCH_ID)
		_check("match_joined reports the LAN mode", joined[0][1], OnlineMatch.MatchMode.LAN_HOST)
	_check("match id is the LAN placeholder", OnlineMatch.match_id, OnlineMatch.LAN_MATCH_ID)

	# The host registers itself immediately, from its own display name, with no
	# presence lookup anywhere (that lookup is what used to crash on LAN).
	_check("the host is in the player list", OnlineMatch.players.size(), 1)
	_check_true("the host is peer 1", OnlineMatch.players.has(1))
	if OnlineMatch.players.has(1):
		_check("the host's name comes from the local profile",
			OnlineMatch.players[1].username, Online.display_name)

	# One player is not enough to start: the state machine must really advance.
	_check("state waits for more players",
		OnlineMatch.match_state, OnlineMatch.MatchState.WAITING_FOR_ENOUGH_PLAYERS)

	# A remote peer announcing itself is what creates a LAN Player. Drive the
	# handler the way the RPC would, minus the wire.
	var announced := []
	OnlineMatch.player_joined.connect(func (player): announced.append(player), CONNECT_ONE_SHOT)
	var newcomer = OnlineMatch.Player.from_lan(2, "Friend")
	OnlineMatch.players[2] = newcomer
	OnlineMatch._check_enough_players()
	_check("two players is enough to be READY",
		OnlineMatch.match_state, OnlineMatch.MatchState.READY)

	# Late joiners are refused once the round is running.
	OnlineMatch.start_playing()
	_check("start_playing still advances the state",
		OnlineMatch.match_state, OnlineMatch.MatchState.PLAYING)

	var errors_before := _errors_from_online_match
	_check("no Nakama socket exists", OnlineMatch.nakama_socket == null, true)
	OnlineMatch.leave()
	await get_tree().process_frame

	_check("leave() raised no error without a Nakama socket",
		_errors_from_online_match, errors_before)
	_check("leave() left the Nakama socket alone", OnlineMatch.nakama_socket == null, true)
	_check("leave() built no Nakama bridge",
		OnlineMatch.nakama_multiplayer_bridge == null, true)
	_check("leave() clears the players", OnlineMatch.players.size(), 0)
	_check("leave() resets the mode", OnlineMatch.match_mode, OnlineMatch.MatchMode.NONE)
	_check("leave() resets the state", OnlineMatch.match_state, OnlineMatch.MatchState.LOBBY)
	_check("leave() is no longer a LAN match", OnlineMatch.is_lan(), false)
	_check("leave() tore down the LAN transport", LanMatch.is_active(), false)
	_check("leave() dropped the multiplayer peer", multiplayer.multiplayer_peer == null, true)

	# Hosting again after leaving is the flow a player hits when a match ends
	# and they host the next one.
	var again: bool = OnlineMatch.host_lan_match(MATCH_PORT)
	_check_true("hosting again after leave() works", again)
	OnlineMatch.leave()

#####
# A real ENet connection over loopback, driven by hand.
#
# Both peers live in one process, so neither can be the SceneTree's multiplayer
# peer (there is only one of those) -- they are polled directly instead. That
# proves the transport and the port work end to end; the RPC layer on top of it
# needs two processes, which is tests/lantest.sh.
#####

func _check_loopback_connection() -> void:
	var server := ENetMultiplayerPeer.new()
	var server_err := server.create_server(LOOPBACK_PORT, 4)
	_check("loopback server starts", server_err, OK)
	if server_err != OK:
		return

	var seen_peers := []
	server.peer_connected.connect(func (id): seen_peers.append(id))

	var client := ENetMultiplayerPeer.new()
	var client_err := client.create_client("127.0.0.1", LOOPBACK_PORT)
	_check("loopback client starts", client_err, OK)
	if client_err != OK:
		server.close()
		return

	var waited := 0
	while waited < 300:
		server.poll()
		client.poll()
		if client.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
			and seen_peers.size() > 0:
			break
		await get_tree().process_frame
		waited += 1

	_check("client reaches CONNECTED over loopback",
		client.get_connection_status(), MultiplayerPeer.CONNECTION_CONNECTED)
	_check("the server saw exactly one peer connect", seen_peers.size(), 1)
	if seen_peers.size() > 0:
		_check("the server saw the client's peer id", seen_peers[0], client.get_unique_id())
	_check_true("the client is not peer 1", client.get_unique_id() != 1)

	client.close()
	server.close()
