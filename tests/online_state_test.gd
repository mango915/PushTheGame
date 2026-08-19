extends Node

# Guards the OnlineMatch state machine.
#
# These properties were previously declared with `set = _set_readonly_variable`
# (an empty setter), which silently discarded every assignment made inside the
# class too. match_state never left LOBBY, leave() never cleared the player list,
# and the matchmaker ticket was never recorded. Nothing errored -- the state
# machine just did nothing -- so only an explicit test catches a regression here.
#
# Runs without a Nakama server: it drives the autoload's own state directly.

var _failures := 0

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[state] OK: %s" % label)
	else:
		_failures += 1
		print("[state] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _ready() -> void:
	print("[state] starting")

	# Assignments to the state properties must actually stick.
	OnlineMatch.match_state = OnlineMatch.MatchState.MATCHING
	_check("match_state is writable", OnlineMatch.match_state, OnlineMatch.MatchState.MATCHING)

	OnlineMatch.match_mode = OnlineMatch.MatchMode.CREATE
	_check("match_mode is writable", OnlineMatch.match_mode, OnlineMatch.MatchMode.CREATE)

	OnlineMatch.matchmaker_ticket = "ticket-123"
	_check("matchmaker_ticket is writable", OnlineMatch.matchmaker_ticket, "ticket-123")

	# start_playing() is what gates late-join rejection.
	OnlineMatch.start_playing()
	_check("start_playing sets PLAYING", OnlineMatch.match_state, OnlineMatch.MatchState.PLAYING)

	# A stale player list across matches was the visible symptom of the bug.
	OnlineMatch.players[99] = OnlineMatch.Player.new("session-99", "ghost", 99)
	_check("player was added", OnlineMatch.players.size(), 1)

	OnlineMatch.leave()
	_check("leave() clears players", OnlineMatch.players.size(), 0)
	_check("leave() resets state", OnlineMatch.match_state, OnlineMatch.MatchState.LOBBY)
	_check("leave() resets mode", OnlineMatch.match_mode, OnlineMatch.MatchMode.NONE)
	_check("leave() clears ticket", OnlineMatch.matchmaker_ticket, "")

	# The handler for a failed create/join must exist; it is connected by name,
	# so a missing method only shows up as a runtime error at failure time.
	_check("match join error handler exists",
		OnlineMatch.has_method("_on_match_join_error"), true)

	print("[state] %d assertion(s) failed" % _failures)
	get_tree().quit(0)
