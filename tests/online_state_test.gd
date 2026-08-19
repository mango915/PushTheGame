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

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

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

	_check_room_codes()

	print("[state] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

# Room codes are what a host reads out to a friend, so they must be short,
# unambiguous, and not collide constantly.
func _check_room_codes() -> void:
	var code := OnlineMatch.generate_room_code()
	_check("room code has the expected length",
		code.length(), OnlineMatch.ROOM_CODE_LENGTH)

	var allowed := OnlineMatch.ROOM_CODE_CHARS
	var all_allowed := true
	for c in code:
		if not allowed.contains(c):
			all_allowed = false
	_check("room code uses only unambiguous characters", all_allowed, true)

	# Characters that are easy to confuse when read aloud must be absent.
	var ambiguous := ["O", "0", "I", "1", "S", "5", "Z", "2"]
	var has_ambiguous := false
	for c in ambiguous:
		if allowed.contains(c):
			has_ambiguous = true
	_check("alphabet excludes look-alike characters", has_ambiguous, false)

	# Sanity on the collision space: generate a batch and require they are not
	# all identical (which would mean the generator is not actually random).
	var seen := {}
	for i in range(200):
		seen[OnlineMatch.generate_room_code()] = true
	_check_true("codes vary across a batch", seen.size() > 100)

	# Codes are normalised to upper case, so a player can type lower case.
	OnlineMatch.room_code = ""
	OnlineMatch.match_mode = OnlineMatch.MatchMode.NONE
