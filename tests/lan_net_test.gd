extends Node

# Two-instance LAN test: one process hosts, the other discovers it and joins.
#
# This is the LAN counterpart of tests/net_test.gd, and the one thing the
# single-process tests cannot do: it exercises real UDP discovery between two
# separate processes, a real ENet connection, the display-name announcement RPC
# that stands in for Nakama presences, and the resulting lobby state.
#
# It needs NO server: no Nakama, no docker, no account, no room code, and the
# joiner is never told an address -- it finds the host by broadcast.
#
# Not run by scripts/check.sh, because it needs two processes plus CLI args.
# Driven by tests/lantest.sh, which launches both roles.
#
# Usage:
#   godot --headless --path . tests/lan_multiplayer.tscn -- host 8676
#   godot --headless --path . tests/lan_multiplayer.tscn -- join 8676

const TIMEOUT_SECONDS := 45.0
# How long the joiner keeps searching before giving up (the host needs a moment
# to bind its beacon).
const DISCOVERY_ATTEMPTS := 8

var _role := ''
var _port := 0
var _failures := 0

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[lan-%s] OK: %s" % [_role, label])
	else:
		_failures += 1
		print("[lan-%s] FAIL: %s (expected %s, got %s)" % [_role, label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("[lan] FAIL: need <host|join> <port>")
		get_tree().quit(1)
		return
	_role = args[0]
	_port = int(args[1])

	_watchdog()
	await _run()

	OnlineMatch.leave()

	print("[lan-%s] %d assertion(s) failed" % [_role, _failures])
	get_tree().quit(1 if _failures > 0 else 0)

func _watchdog() -> void:
	var timer := get_tree().create_timer(TIMEOUT_SECONDS)
	timer.timeout.connect(func ():
		print("[lan-%s] FAIL: timed out after %ds" % [_role, int(TIMEOUT_SECONDS)])
		print("[lan-%s] 1 assertion(s) failed" % _role)
		get_tree().quit(1))

func _run() -> void:
	GameState.online_play = true

	# Each role needs a distinct name, and the name must reach the other side
	# over the announcement RPC -- on a LAN there is no presence list to read it
	# from. Set in memory only, so the developer's profile is left alone.
	Online.display_name = "Lan%s" % _role.capitalize()

	# Nothing below signs in, connects a socket, or touches Nakama at all. That
	# is the point: LAN play must work with no server in existence.
	_check("no Nakama session is needed", Online.has_valid_session(), false)

	if _role == "host":
		await _run_host()
	else:
		await _run_join()

	if OnlineMatch.players.size() < 2:
		return

	# Both sides must see both real names, keyed by peer id -- that dictionary
	# is what Game spawns players from.
	var names := []
	for peer_id in OnlineMatch.players:
		names.append(OnlineMatch.players[peer_id].username)
	names.sort()
	_check("both display names arrived (got %s)" % ", ".join(names),
		names, ["LanHost", "LanJoin"])

	var roster := OnlineMatch.get_player_names_by_peer_id()
	_check("the roster has both peers", roster.size(), 2)
	_check_true("the roster is keyed by peer id", roster.has(1))

	# The state machine must really advance, exactly as it does over Nakama.
	_check("match state reached READY",
		OnlineMatch.match_state, OnlineMatch.MatchState.READY)

	# Prove RPCs actually flow over the LAN peer, in both directions.
	if _role == "host":
		print("[lan-host] sending ping rpc")
		rpc("_lan_ping", "hello-from-host")
		await get_tree().create_timer(3.0).timeout
		_check_true("joiner answered the ping", _pong_received)
	else:
		await get_tree().create_timer(3.0).timeout
		_check_true("received the host's ping", _ping_received)

	print("[lan-%s] leaving" % _role)

func _run_host() -> void:
	print("[lan-host] hosting on port %d" % _port)
	var hosted: bool = OnlineMatch.host_lan_match(_port)
	_check_true("host_lan_match succeeds with no server", hosted)
	if not hosted:
		return

	_check("host is peer 1", multiplayer.get_unique_id(), 1)
	_check("match mode is LAN_HOST", OnlineMatch.match_mode, OnlineMatch.MatchMode.LAN_HOST)
	_check("the host is already in its own lobby", OnlineMatch.players.size(), 1)

	print("[lan-host] waiting for a player to find us...")
	await _wait_for_two_players()
	_check("both players are in the match", OnlineMatch.players.size(), 2)

func _run_join() -> void:
	# Give the host time to bind its beacon.
	await get_tree().create_timer(2.0).timeout

	var found := {}
	for attempt in range(DISCOVERY_ATTEMPTS):
		print("[lan-join] searching the network (attempt %d)..." % (attempt + 1))
		var hosts: Array = await LanMatch.discover_hosts()
		for host in hosts:
			if host.port == _port:
				found = host
		if not found.is_empty():
			break

	_check_true("discovery found a game on the network", not found.is_empty())
	if found.is_empty():
		return

	# Nobody typed an address: it came from the discovery reply.
	_check("the discovered game advertises the host's name", found.name, "LanHost")
	_check("the discovered game advertises the game port", found.port, _port)
	_check_true("the discovered game has an address (%s)" % found.address, found.address != '')
	_check_true("the discovered game reports its player count (%d/%d)"
		% [found.players, found.max_players], found.players >= 1)

	print("[lan-join] joining %s at %s:%d" % [found.name, found.address, found.port])
	var joining: bool = OnlineMatch.join_lan_match(found.address, found.port)
	_check_true("join_lan_match accepted the discovered address", joining)
	if not joining:
		return

	await OnlineMatch.match_joined
	_check("match mode is LAN_JOIN", OnlineMatch.match_mode, OnlineMatch.MatchMode.LAN_JOIN)
	_check_true("the joiner is not peer 1", multiplayer.get_unique_id() != 1)

	await _wait_for_two_players()
	_check("both players are in the match", OnlineMatch.players.size(), 2)

func _wait_for_two_players() -> void:
	var waited := 0.0
	while OnlineMatch.players.size() < 2 and waited < 25.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5

var _ping_received := false
var _pong_received := false

@rpc("any_peer", "call_remote", "reliable") func _lan_ping(message: String) -> void:
	print("[lan-%s] got ping: %s" % [_role, message])
	_ping_received = true
	rpc_id(multiplayer.get_remote_sender_id(), "_lan_pong", "hello-back")

@rpc("any_peer", "call_remote", "reliable") func _lan_pong(message: String) -> void:
	print("[lan-%s] got pong: %s" % [_role, message])
	_pong_received = true
