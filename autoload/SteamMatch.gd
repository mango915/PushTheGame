extends Node

# Steam multiplayer: friends, invites and the network transport.
#
# This is the third transport, alongside Nakama (autoload/Online.gd +
# OnlineMatch's bridge) and LAN (autoload/LanMatch.gd). It is shaped exactly
# like LanMatch on purpose: it owns nothing but the transport and a little
# lobby bookkeeping, installs a MultiplayerPeer, and lets OnlineMatch keep
# doing the peer-id based match management it already does for the other two.
# Main, Game and ReadyScreen stay transport-agnostic.
#
# WHAT MAKES THIS FILE UNUSUAL
#
# GodotSteam is a GDExtension that this project does not ship. When it is not
# installed there is no `Steam` singleton and no `SteamMultiplayerPeer` class,
# and a bare reference to either identifier would fail to resolve and take the
# whole script (and therefore this autoload, and therefore the game) down with
# it. So nothing here names them directly:
#
#   - the singleton is fetched once through Engine.get_singleton("Steam") and
#     every call goes through _steam_call(), which checks the method exists,
#   - the peer is built with ClassDB.instantiate("SteamMultiplayerPeer"),
#   - every public entry point returns false / an empty value and emits
#     steam_error when Steam is absent, instead of erroring.
#
# The consequence is that with GodotSteam missing the game behaves exactly as
# it did before this file existed, and the Steam UI is visibly disabled with a
# reason. See docs/steam.md for what has to be installed to make it live.
#
# NOTHING HERE HAS BEEN RUN AGAINST A REAL STEAM CLIENT. The API names and
# signatures come from the GodotSteam documentation (see docs/steam.md); the
# guarded, Steam-absent paths are what the tests cover.

# Identifies our lobbies in a lobby-list search, so we never try to join some
# other game's lobby if a filtered search is ever added.
const LOBBY_GAME_ID := 'push_the_game'

const LOBBY_KEY_GAME := 'game'
const LOBBY_KEY_HOST := 'host'
const LOBBY_KEY_VERSION := 'version'

# Steam's own enums, spelled out because the constants live on the singleton
# and we cannot read them when it is absent. Values from the GodotSteam docs.
const LOBBY_TYPE_PRIVATE := 0
const LOBBY_TYPE_FRIENDS_ONLY := 1
const LOBBY_TYPE_PUBLIC := 2
const LOBBY_TYPE_INVISIBLE := 3

# SteamAPIInitResult
const INIT_RESULT_OK := 0
# Result
const RESULT_OK := 1
# ChatRoomEnterResponse
const CHAT_ROOM_ENTER_RESPONSE_SUCCESS := 1
# FriendFlags: the user's "regular" friends.
const FRIEND_FLAG_IMMEDIATE := 0x04
# PersonaState
const PERSONA_STATE_OFFLINE := 0

# ChatMemberStateChange bitfield.
const CHAT_MEMBER_STATE_ENTERED := 0x0001
const CHAT_MEMBER_STATE_LEFT := 0x0002
const CHAT_MEMBER_STATE_DISCONNECTED := 0x0004
const CHAT_MEMBER_STATE_KICKED := 0x0008
const CHAT_MEMBER_STATE_BANNED := 0x0010

# Valve's "Spacewar" test app id. Works for development without owning a real
# app id; a shipped build must use its own. See docs/steam.md.
const SPACEWAR_APP_ID := 480

# Where GodotSteam itself keeps its configuration, when it is installed. Both
# are read rather than assumed: whatever the owner set in Project Settings has
# to win, or we would pump callbacks twice (or not at all).
const APP_ID_SETTING := 'steam/initialization/app_id'
const EMBED_CALLBACKS_SETTING := 'steam/initialization/embed_callbacks'

# The message the UI shows when there is nothing to talk to.
const UNAVAILABLE_MESSAGE := 'GodotSteam is not installed - see docs/steam.md'

signal steam_ready ()
signal steam_error (message)
# The lobby exists and the multiplayer peer is installed: a match can start.
signal lobby_ready (lobby_id)
signal lobby_left ()
signal friends_updated (friends)
# Somebody invited us but has not been accepted yet (Steam shows its own
# notification for this too).
signal invite_received (lobby_id, friend_steam_id, friend_name)
# The player accepted an invite, or hit "Join Game" on a friend. This is the
# signal that actually makes us join: OnlineMatch listens for it.
signal invite_accepted (lobby_id, friend_steam_id)

# The app id used by initialize(). Settable before initialize() runs.
var app_id: int = SPACEWAR_APP_ID

# The lobby we are in, 0 when we are in none.
var current_lobby: int = 0
# True when this instance created current_lobby.
var hosting := false
# Last failure, for callers that want to show it. Cleared by every successful
# call, exactly like LanMatch.last_error.
var last_error: String = ''

# Set when a lobby id arrived from the command line (`+connect_lobby <id>`,
# which is how Steam launches the game when an invite is accepted while the
# game is closed). Consumed by take_pending_invite().
var pending_invite_lobby: int = 0

# The Steam singleton, or null. Never named directly anywhere else.
var _steam: Object = null
var _initialized := false
# steamInitEx(app_id, embed_callbacks): when callbacks are embedded Steam
# pumps them itself and _process must not.
var _embed_callbacks := false
var _peer = null
# createLobby is asynchronous; this remembers that the pending lobby is ours to
# host, so lobby_joined (which also fires for the creator) does not try to
# connect to it a second time as a client.
var _creating_lobby := false
var _joining_lobby: int = 0

func _ready() -> void:
	_steam = _find_steam_singleton()
	# Reading the command line is free and works with or without Steam; the
	# lobby is only acted on once Steam is up.
	pending_invite_lobby = parse_command_line_lobby(OS.get_cmdline_args())

	# A Steam build has to come up initialised, not initialise on first use: the
	# invite callbacks (join_requested) only arrive while run_callbacks() is
	# being pumped, and a friend can invite us at any moment -- including while
	# we are playing on a LAN or on Nakama. Skipped entirely when GodotSteam is
	# absent, so boot is byte for byte what it was without this autoload.
	if is_available():
		initialize()

#####
# Availability
#####

# True when the GodotSteam GDExtension is loaded in this build. Everything
# public below is a no-op that emits steam_error when this is false.
func is_available() -> bool:
	return _steam != null

# True when the SteamMultiplayerPeer class is present as well. It lives in the
# main GodotSteam branches; an old MultiplayerPeer-less build would give us
# lobbies and invites but no transport, and that is worth reporting distinctly.
func has_multiplayer_peer() -> bool:
	return ClassDB.class_exists('SteamMultiplayerPeer') \
		and ClassDB.can_instantiate('SteamMultiplayerPeer')

func is_ready() -> bool:
	return _initialized

# One line for the UI to show under the Steam buttons.
func status_text() -> String:
	if not is_available():
		return UNAVAILABLE_MESSAGE
	if not has_multiplayer_peer():
		return 'GodotSteam has no SteamMultiplayerPeer - see docs/steam.md'
	if not is_ready():
		return last_error if last_error != '' else 'Steam is not connected'
	if is_busy():
		return 'Talking to Steam...'
	if current_lobby != 0:
		return 'Steam lobby open - invite your friends'
	return 'Signed in as %s' % get_persona_name()

func _find_steam_singleton() -> Object:
	if not Engine.has_singleton('Steam'):
		return null
	return Engine.get_singleton('Steam')

#####
# Initialisation
#####

# Brings the Steamworks API up. Safe (and cheap) to call repeatedly: the second
# call is a no-op once initialisation succeeded.
func initialize() -> bool:
	if _initialized:
		return true
	if not is_available():
		return _fail(UNAVAILABLE_MESSAGE)

	var configured := _configured_app_id()
	if configured > 0:
		app_id = configured

	# If the project is configured to have GodotSteam pump callbacks itself,
	# honour that and keep _process out of it.
	_embed_callbacks = _configured_embed_callbacks()

	var result = _steam_call('steamInitEx', [app_id, _embed_callbacks])
	if result == null:
		# An older GodotSteam without steamInitEx. steamInit returns a plain
		# bool (or a dictionary in some builds), so treat anything truthy as
		# success rather than guessing at a shape.
		result = _steam_call('steamInit', [])
		if result == null:
			return _fail('This GodotSteam build has no steamInitEx()')
		if typeof(result) == TYPE_BOOL:
			if not result:
				return _fail('Steam could not be initialised - is the Steam client running?')
			return _initialized_ok()

	if typeof(result) != TYPE_DICTIONARY:
		return _fail('Steam returned an unexpected initialisation result')

	var status := int(result.get('status', -1))
	if status != INIT_RESULT_OK:
		var verbal := str(result.get('verbal', ''))
		if verbal == '':
			verbal = 'Steam could not be initialised (status %d)' % status
		return _fail(verbal)

	return _initialized_ok()

func _initialized_ok() -> bool:
	_initialized = true
	last_error = ''
	_connect_steam_signals()
	emit_signal('steam_ready')
	return true

# Initialises on demand so the UI never has to sequence this itself.
func _ensure_ready() -> bool:
	if _initialized:
		return true
	return initialize()

func _configured_app_id() -> int:
	# GodotSteam registers this project setting when it is installed; when it
	# is not, has_setting() is false and we keep our own default.
	if ProjectSettings.has_setting(APP_ID_SETTING):
		return int(ProjectSettings.get_setting(APP_ID_SETTING, 0))
	return 0

func _configured_embed_callbacks() -> bool:
	if ProjectSettings.has_setting(EMBED_CALLBACKS_SETTING):
		return bool(ProjectSettings.get_setting(EMBED_CALLBACKS_SETTING, false))
	return false

func is_steam_running() -> bool:
	if not is_available():
		return false
	return bool(_steam_call_or('isSteamRunning', [], false))

# Steam delivers its callbacks on a pump we have to turn, unless the extension
# was asked to embed it. Cheap enough to leave in _process; it does nothing at
# all when Steam is absent.
func _process(_delta: float) -> void:
	if not _initialized or _embed_callbacks:
		return
	_steam_call('run_callbacks', [])

#####
# Identity
#####

func get_persona_name() -> String:
	if not is_available():
		return ''
	return str(_steam_call_or('getPersonaName', [], ''))

func get_steam_id() -> int:
	if not is_available():
		return 0
	return int(_steam_call_or('getSteamID', [], 0))

#####
# Hosting and joining
#####

# Creates a Steam lobby and, once Steam confirms it, installs the transport.
#
# Asynchronous by nature: this returns true when the request went out, and
# lobby_ready fires when the lobby exists and the peer is up. Failures arrive
# as steam_error, which OnlineMatch forwards to the UI.
func host_lobby(friends_only: bool = true, max_members: int = 0) -> bool:
	if not _ensure_ready():
		return false
	if not has_multiplayer_peer():
		return _fail('GodotSteam has no SteamMultiplayerPeer - see docs/steam.md')

	leave()

	if max_members <= 0:
		max_members = _max_players()
	max_members = clampi(max_members, 2, 250)

	var lobby_type := LOBBY_TYPE_FRIENDS_ONLY if friends_only else LOBBY_TYPE_PUBLIC
	_creating_lobby = true
	if _steam_call('createLobby', [lobby_type, max_members]) == null:
		_creating_lobby = false
		return _fail('This GodotSteam build has no createLobby()')

	last_error = ''
	return true

# Joins a lobby we were invited to (or picked out of a list). The transport is
# installed from the lobby_joined callback.
func join_lobby(lobby_id: int) -> bool:
	if lobby_id <= 0:
		return _fail('That Steam lobby is not valid')
	if not _ensure_ready():
		return false
	if not has_multiplayer_peer():
		return _fail('GodotSteam has no SteamMultiplayerPeer - see docs/steam.md')

	leave()

	_joining_lobby = lobby_id
	if _steam_call('joinLobby', [lobby_id]) == null:
		_joining_lobby = 0
		return _fail('This GodotSteam build has no joinLobby()')

	last_error = ''
	return true

# Drops the lobby and the multiplayer peer. A no-op when nothing is running,
# and safe to call twice -- OnlineMatch.leave() calls it unconditionally.
func leave() -> void:
	var had_lobby := current_lobby != 0

	if current_lobby != 0 and is_available():
		_steam_call('leaveLobby', [current_lobby])

	current_lobby = 0
	hosting = false
	_creating_lobby = false
	_joining_lobby = 0

	_drop_peer()

	if had_lobby:
		emit_signal('lobby_left')

func _drop_peer() -> void:
	if _peer == null:
		return
	# Detach before closing so teardown does not fire a storm of
	# peer_disconnected signals into OnlineMatch while it is already leaving.
	var tree := get_tree()
	if tree != null:
		var multiplayer_api := tree.get_multiplayer()
		if multiplayer_api != null and multiplayer_api.multiplayer_peer == _peer:
			multiplayer_api.multiplayer_peer = null
	if _peer.has_method('close'):
		_peer.close()
	_peer = null

func is_active() -> bool:
	return _peer != null

# True between asking Steam for a lobby and Steam answering. Lobby creation and
# lobby joining are both round trips to Steam's servers, so there is a window in
# which neither "no lobby" nor "in a lobby" is the truth.
func is_busy() -> bool:
	return _creating_lobby or _joining_lobby != 0

#####
# Friends and invites
#####

# The friend list for the invite UI: [{steam_id, name, online}].
# Empty (never null) when Steam is absent, so the UI can iterate blindly.
func get_friends(online_only: bool = true) -> Array:
	var friends := []
	if not is_available() or not _initialized:
		return friends

	var count := int(_steam_call_or('getFriendCount', [FRIEND_FLAG_IMMEDIATE], 0))
	# getFriendCount returns -1 when the user is not logged on.
	for i in range(max(0, count)):
		var steam_id := int(_steam_call_or('getFriendByIndex', [i, FRIEND_FLAG_IMMEDIATE], 0))
		if steam_id == 0:
			continue
		var state := int(_steam_call_or('getFriendPersonaState', [steam_id], PERSONA_STATE_OFFLINE))
		var online := state != PERSONA_STATE_OFFLINE
		if online_only and not online:
			continue
		var friend_name := str(_steam_call_or('getFriendPersonaName', [steam_id], ''))
		if friend_name == '':
			friend_name = str(steam_id)
		friends.append({
			steam_id = steam_id,
			name = friend_name,
			online = online,
		})

	friends.sort_custom(func(a, b): return String(a.name).nocasecmp_to(String(b.name)) < 0)
	return friends

# Re-reads the friend list and announces it. The UI listens for
# friends_updated rather than polling.
func refresh_friends(online_only: bool = true) -> Array:
	var friends := get_friends(online_only)
	emit_signal('friends_updated', friends)
	return friends

# Sends one friend an invite to the lobby we are hosting.
func invite_friend(steam_id: int) -> bool:
	if not is_available():
		return _fail(UNAVAILABLE_MESSAGE)
	if not _initialized:
		return _fail('Steam is not connected')
	if current_lobby == 0:
		return _fail('Host a Steam game before inviting anyone')
	if steam_id <= 0:
		return _fail('That friend is not valid')

	if _steam_call('inviteUserToLobby', [current_lobby, steam_id]) == null:
		return _fail('This GodotSteam build has no inviteUserToLobby()')

	last_error = ''
	return true

# Opens Steam's own invite dialog, which is what most players expect. Needs the
# overlay, so it does nothing visible when the game runs outside Steam.
func open_invite_overlay() -> bool:
	if not is_available():
		return _fail(UNAVAILABLE_MESSAGE)
	if not _initialized:
		return _fail('Steam is not connected')
	if current_lobby == 0:
		return _fail('Host a Steam game before inviting anyone')

	if _steam_call('activateGameOverlayInviteDialog', [current_lobby]) == null:
		return _fail('This GodotSteam build has no activateGameOverlayInviteDialog()')

	last_error = ''
	return true

# Steam launches the game with `+connect_lobby <id>` when an invite is accepted
# while the game is closed. Pure parsing, so it is testable without Steam.
static func parse_command_line_lobby(args: Array) -> int:
	for i in range(args.size()):
		var argument := str(args[i])
		if argument == '+connect_lobby':
			if i + 1 < args.size():
				return _to_lobby_id(args[i + 1])
			return 0
		# Some launchers hand it over as a single `+connect_lobby=<id>` token.
		if argument.begins_with('+connect_lobby='):
			return _to_lobby_id(argument.substr('+connect_lobby='.length()))
	return 0

static func _to_lobby_id(value) -> int:
	var text := str(value).strip_edges()
	if not text.is_valid_int():
		return 0
	var lobby_id := int(text)
	return lobby_id if lobby_id > 0 else 0

# Hands over (and clears) a lobby id that arrived on the command line.
func take_pending_invite() -> int:
	var lobby_id := pending_invite_lobby
	pending_invite_lobby = 0
	return lobby_id

# Acts on a `+connect_lobby` id from the command line by raising the same
# invite_accepted everyone already listens for, so the boot-time path and the
# in-game path behave identically. Returns false when there is nothing pending
# (the usual case) or when Steam is not there to join with.
func accept_pending_invite() -> bool:
	if pending_invite_lobby == 0:
		return false
	var lobby_id := take_pending_invite()
	if not is_available():
		return false
	emit_signal('invite_accepted', lobby_id, 0)
	return true

#####
# Steam callbacks
#####

func _connect_steam_signals() -> void:
	if _steam == null:
		return
	# Arities are taken from the singleton itself rather than hard-coded: the
	# documented parameter lists have gained fields between GodotSteam versions
	# (lobby_joined grew a `response`), and connecting a callable that takes
	# fewer arguments than the signal emits is an error in Godot 4.
	connect_adapting(_steam, 'lobby_created', Callable(self, '_on_lobby_created'), 2)
	connect_adapting(_steam, 'lobby_joined', Callable(self, '_on_lobby_joined'), 4)
	connect_adapting(_steam, 'lobby_chat_update', Callable(self, '_on_lobby_chat_update'), 4)
	connect_adapting(_steam, 'lobby_invite', Callable(self, '_on_lobby_invite'), 3)
	connect_adapting(_steam, 'join_requested', Callable(self, '_on_join_requested'), 2)

# Connects `callable` (which accepts `handler_arity` arguments, the trailing
# ones defaulted) to a signal whose real arity we only learn at runtime.
# Extra emitted arguments are unbound; missing ones fall back to the defaults.
func connect_adapting(target: Object, signal_name: String, callable: Callable, handler_arity: int) -> bool:
	if target == null or not target.has_signal(signal_name):
		return false
	var emitted := signal_arity(target, signal_name)
	var adapted := callable
	if emitted > handler_arity:
		adapted = callable.unbind(emitted - handler_arity)
	if target.is_connected(signal_name, adapted):
		return true
	return target.connect(signal_name, adapted) == OK

# How many arguments a signal actually carries, or -1 when there is no such
# signal on the object.
static func signal_arity(target: Object, signal_name: String) -> int:
	if target == null:
		return -1
	for entry in target.get_signal_list():
		if str(entry.get('name', '')) == signal_name:
			var args = entry.get('args', [])
			return (args as Array).size()
	return -1

# createLobby finished. `connect_result` is a Result enum, `lobby_id` is 0 on
# failure. Documented as lobby_created(connect, lobby).
func _on_lobby_created(connect_result: int = 0, lobby_id: int = 0) -> void:
	_creating_lobby = false

	if connect_result != RESULT_OK or lobby_id == 0:
		_fail('Steam could not create a lobby (result %d)' % connect_result)
		return

	current_lobby = lobby_id
	hosting = true

	_steam_call('setLobbyJoinable', [lobby_id, true])
	_steam_call('setLobbyData', [lobby_id, LOBBY_KEY_GAME, LOBBY_GAME_ID])
	_steam_call('setLobbyData', [lobby_id, LOBBY_KEY_HOST, _host_name()])
	_steam_call('setLobbyData', [lobby_id, LOBBY_KEY_VERSION, _client_version()])

	if not _install_peer('host_with_lobby', lobby_id):
		return

	emit_signal('lobby_ready', lobby_id)

# We entered a lobby. Fires for the host too, right after lobby_created, in
# which case the transport is already up and there is nothing to do.
func _on_lobby_joined(lobby_id: int = 0, _permissions: int = 0, _locked: bool = false, response: int = CHAT_ROOM_ENTER_RESPONSE_SUCCESS) -> void:
	if response != CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		_joining_lobby = 0
		_fail('Could not join that Steam lobby (response %d)' % response)
		return

	if hosting and lobby_id == current_lobby:
		return

	_joining_lobby = 0
	current_lobby = lobby_id
	hosting = false

	if not _install_peer('connect_to_lobby', lobby_id):
		return

	emit_signal('lobby_ready', lobby_id)

# Builds the SteamMultiplayerPeer and installs it as the engine's transport.
# `method` is host_with_lobby or connect_to_lobby.
func _install_peer(method: String, lobby_id: int) -> bool:
	_drop_peer()

	if not has_multiplayer_peer():
		return _fail('GodotSteam has no SteamMultiplayerPeer - see docs/steam.md')

	var peer = ClassDB.instantiate('SteamMultiplayerPeer')
	if peer == null:
		return _fail('Could not create a SteamMultiplayerPeer')
	if not peer.has_method(method):
		return _fail('SteamMultiplayerPeer has no %s()' % method)

	var err = peer.call(method, lobby_id)
	if typeof(err) == TYPE_INT and err != OK:
		return _fail('Steam transport failed to start (error %d)' % err)

	_peer = peer
	var tree := get_tree()
	if tree != null:
		tree.get_multiplayer().multiplayer_peer = peer
	last_error = ''
	return true

# Somebody joined or left the lobby. The transport reports peers of its own, so
# this is only used to notice the lobby emptying out.
func _on_lobby_chat_update(lobby_id: int = 0, _changed_id: int = 0, _making_change_id: int = 0, _chat_state: int = 0) -> void:
	if lobby_id != current_lobby:
		return
	# Deliberately no bookkeeping here: OnlineMatch owns the player list and
	# gets peer_connected/peer_disconnected from the transport, exactly as it
	# does on a LAN. Kept connected because it is the hook a lobby browser or a
	# "player joined" sound would use.

# We were invited. Steam shows its own notification; this lets the game show
# one in-game too. It does NOT join -- join_requested is what means "accepted".
func _on_lobby_invite(inviter: int = 0, lobby: int = 0, _game: int = 0) -> void:
	var friend_name := ''
	if inviter != 0:
		friend_name = str(_steam_call_or('getFriendPersonaName', [inviter], ''))
	emit_signal('invite_received', lobby, inviter, friend_name)

# The player accepted an invite, or picked "Join Game" on a friend, while the
# game was running. This is the flow that has to end in us being in their match.
func _on_join_requested(lobby: int = 0, steam_id: int = 0) -> void:
	if lobby <= 0:
		return
	emit_signal('invite_accepted', lobby, steam_id)

#####
# Guarded access to the singleton
#####

# Calls a method on the Steam singleton if both exist. Returns null when the
# call could not be made, which is how every caller detects a missing API
# without ever naming the singleton.
func _steam_call(method: String, args: Array = []):
	if _steam == null or not _steam.has_method(method):
		return null
	return _steam.callv(method, args)

# _steam_call with a fallback, for calls whose real result may legitimately be
# null-ish.
func _steam_call_or(method: String, args: Array, fallback):
	if _steam == null or not _steam.has_method(method):
		return fallback
	var result = _steam.callv(method, args)
	if result == null:
		return fallback
	return result

# Records a failure, announces it, and returns false so callers can
# `return _fail(...)`.
func _fail(message: String) -> bool:
	last_error = message
	push_warning('SteamMatch: %s' % message)
	emit_signal('steam_error', message)
	return false

#####
# Details borrowed from the rest of the game, kept tolerant so this class can be
# driven on its own (which is what the tests do).
#####

func _host_name() -> String:
	var host_name := ''
	var online := get_node_or_null('/root/Online')
	if online != null:
		host_name = str(online.display_name).strip_edges()
	if host_name == '' and is_available():
		host_name = get_persona_name()
	if host_name == '':
		host_name = 'Steam game'
	return host_name

func _client_version() -> String:
	var online_match := get_node_or_null('/root/OnlineMatch')
	if online_match == null:
		return 'dev'
	return str(online_match.client_version)

func _max_players() -> int:
	var online_match := get_node_or_null('/root/OnlineMatch')
	if online_match == null:
		return 4
	return int(online_match.max_players)
