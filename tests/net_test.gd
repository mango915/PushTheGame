extends Node

# Two-client multiplayer test against a real Nakama server.
#
# This is the one thing the rest of the harness cannot do: everything else runs
# a single process with no server, so the whole online path -- device auth,
# socket connect, named-match host/join, peer id assignment, presence -- was
# previously only verified by reading the code.
#
# Not run by scripts/check.sh, because it needs `docker compose up -d`.
# Driven by scripts/nettest.sh, which launches both roles.
#
# Usage:
#   godot --headless --path . tests/net_multiplayer.tscn -- host ABCD
#   godot --headless --path . tests/net_multiplayer.tscn -- join ABCD

const TIMEOUT_SECONDS := 45.0

var _role := ''
var _code := ''
var _failures := 0
var _saved_settings := ''
var _saved_profile := ''

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[net-%s] OK: %s" % [_role, label])
	else:
		_failures += 1
		print("[net-%s] FAIL: %s (expected %s, got %s)" % [_role, label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _fail(label: String) -> void:
	_failures += 1
	print("[net-%s] FAIL: %s" % [_role, label])

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("[net] FAIL: need <host|join> <code>")
		get_tree().quit(1)
		return
	_role = args[0]
	_code = args[1]

	# Do not clobber the developer's real profile/server choice.
	_saved_settings = _read_raw(Online.SETTINGS_FILENAME)
	_saved_profile = _read_raw(Online.PROFILE_FILENAME)

	_watchdog()
	await _run()

	_write_raw(Online.SETTINGS_FILENAME, _saved_settings)
	_write_raw(Online.PROFILE_FILENAME, _saved_profile)

	print("[net-%s] %d assertion(s) failed" % [_role, _failures])
	get_tree().quit(1 if _failures > 0 else 0)

func _watchdog() -> void:
	var timer := get_tree().create_timer(TIMEOUT_SECONDS)
	timer.timeout.connect(func ():
		print("[net-%s] FAIL: timed out after %ds" % [_role, int(TIMEOUT_SECONDS)])
		print("[net-%s] 1 assertion(s) failed" % _role)
		get_tree().quit(1))

func _run() -> void:
	GameState.online_play = true

	# Point at the local docker server, and give each role its own device id --
	# otherwise both clients authenticate as the SAME Nakama user, which is not
	# what two players look like.
	Online.apply_server_settings("127.0.0.1", 7350, "http")
	# Stable per-role device id, deliberately NOT derived from the room code:
	# a fresh device id mints a fresh Nakama account each run, which then
	# collides with the previous run on the hard-coded username and fails with
	# "409 Username is already in use" forever after the first run.
	Online._device_id = "nettest-%s" % _role
	Online.display_name = "Test%s" % _role.capitalize()

	print("[net-%s] authenticating..." % _role)
	var signed_in: bool = await Online.ensure_session()
	_check_true("device authentication succeeds", signed_in)
	if not signed_in:
		return
	_check_true("session is valid", Online.has_valid_session())
	# May carry a "#1234" suffix if the plain name was already taken.
	var expected_name := "Test%s" % _role.capitalize()
	_check_true("display name reached the server (got %s)" % Online.nakama_session.username,
		Online.nakama_session.username.begins_with(expected_name))

	print("[net-%s] connecting socket..." % _role)
	var connected: bool = await Online.connect_nakama_socket()
	_check_true("socket connects", connected)
	if not connected:
		return

	# The joiner gives the host a head start, so the named match exists.
	if _role == "join":
		await get_tree().create_timer(4.0).timeout

	print("[net-%s] entering room %s" % [_role, _code])
	if _role == "host":
		OnlineMatch.host_room(Online.nakama_socket, _code)
	else:
		OnlineMatch.join_room(Online.nakama_socket, _code)

	await OnlineMatch.match_joined
	print("[net-%s] joined match %s" % [_role, OnlineMatch.match_id])

	_check("room code is recorded", OnlineMatch.room_code, _code)
	_check_true("match id is set", OnlineMatch.match_id != "")

	var my_peer_id := multiplayer.get_unique_id()
	print("[net-%s] my peer id is %d" % [_role, my_peer_id])
	if _role == "host":
		# Named matches promote the first player in to host, which the bridge
		# expresses as peer id 1.
		_check("host is peer 1", my_peer_id, 1)
	else:
		_check_true("joiner is not peer 1", my_peer_id != 1)

	# Wait for the other player's presence to arrive.
	print("[net-%s] waiting for the other player..." % _role)
	var waited := 0.0
	while OnlineMatch.players.size() < 2 and waited < 25.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5

	_check("both players are in the match", OnlineMatch.players.size(), 2)
	if OnlineMatch.players.size() < 2:
		return

	# Each side should see the other's chosen name, not a placeholder.
	var names := []
	for peer_id in OnlineMatch.players:
		names.append(OnlineMatch.players[peer_id].username)
	names.sort()
	_check_true("both usernames visible (got %s)" % ", ".join(names),
		names.size() == 2 and names[0].begins_with("TestHost") and names[1].begins_with("TestJoin"))

	# match_state must have actually advanced -- this is the property whose
	# no-op setter made the whole state machine inert.
	_check_true("match state left LOBBY",
		OnlineMatch.match_state == OnlineMatch.MatchState.READY)

	# The host proves the RPC channel really carries traffic both ways.
	if _role == "host":
		print("[net-host] sending ping rpc")
		rpc("_net_ping", "hello-from-host")
		await get_tree().create_timer(3.0).timeout
		_check_true("joiner answered the ping", _pong_received)
	else:
		await get_tree().create_timer(3.0).timeout
		_check_true("received the host's ping", _ping_received)

	print("[net-%s] leaving" % _role)
	OnlineMatch.leave()

var _ping_received := false
var _pong_received := false

@rpc("any_peer", "call_remote", "reliable") func _net_ping(message: String) -> void:
	print("[net-%s] got ping: %s" % [_role, message])
	_ping_received = true
	rpc_id(multiplayer.get_remote_sender_id(), "_net_pong", "hello-back")

@rpc("any_peer", "call_remote", "reliable") func _net_pong(message: String) -> void:
	print("[net-%s] got pong: %s" % [_role, message])
	_pong_received = true

func _read_raw(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	var text := f.get_as_text()
	f.close()
	return text

func _write_raw(path: String, text: String) -> void:
	if text == "":
		DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
