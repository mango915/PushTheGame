extends Node

# Match-lifecycle regressions in Main.gd / Game.gd that need no server.
#
# Everything here is reachable from a single headless process: local play scores
# and can be won, a torn-down match forgets its scoreboard, the ready tally
# believes the sender rather than the message, and a departed peer's player is
# really removed. The online-only halves of the same code paths are covered by
# tests/net_test.gd against a real Nakama.

const MainScene := preload("res://Main.tscn")

# Time show_winner() waits before restarting the round, plus a margin.
const ROUND_GAP := 2.5

var _failures := 0
var _main: Node

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[match] OK: %s" % label)
	else:
		_failures += 1
		print("[match] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

# Which screen is up is read from the node itself: UILayer.current_screen is
# declared with an empty setter (`set = _set_readonly_variable`), so every
# assignment to it is silently discarded and current_screen_name is always ''.
# That is a live bug in main/UILayer.gd, not something this test should assert
# around -- see the report.
func _screen_visible(screen_name: String) -> bool:
	var screen = _main.ui_layer.get_node_or_null("Screens/" + screen_name)
	return screen != null and screen.visible

func _ready() -> void:
	print("[match] booting Main.tscn")
	_main = MainScene.instantiate()
	add_child(_main)

	# Let Main and UILayer finish their own _ready pass before driving them.
	await get_tree().process_frame
	await get_tree().process_frame

	GameState.online_play = false
	OnlineMatch.leave()

	# Rounds are paced by GameSettings.round_countdown, which holds the paused
	# tree for a beat before play begins. Real play wants it; a test does not
	# want its wall-clock decided by it.
	_main.game.get_game_settings().round_countdown = 0.0

	_check_roster_signal()
	_check_setup_report_guard()
	_check_ready_tally()
	await _check_local_scoring()
	await _check_four_player_match()
	await _check_teardown_resets_score()
	await _check_departed_player_is_removed()

	GameState.online_play = false
	_main.stop_game()

	print("[match] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

# Main.players is assigned in start_game(), which only the host ever calls. The
# roster has to reach every peer some other way or a client believes the match
# is empty for its whole duration.
func _check_roster_signal() -> void:
	_main.players.clear()
	_main.game.emit_signal("roster_updated", {11: "Ann", 12: "Bob"})
	_check("the roster from Game reaches Main", _main.players.size(), 2)
	_check("the roster keeps the peer ids", _main.players.get(12, ""), "Bob")

	# Starting a round is also what tells a client the match has begun; without
	# it the client keeps accepting joiners the host has already booted.
	GameState.online_play = true
	OnlineMatch.match_state = OnlineMatch.MatchState.READY
	_main.game.emit_signal("roster_updated", {11: "Ann", 12: "Bob"})
	_check("a starting round advances match_state to PLAYING",
		OnlineMatch.match_state, OnlineMatch.MatchState.PLAYING)

	GameState.online_play = false
	OnlineMatch.leave()
	_main.players.clear()

# _finished_game_setup() indexes players_alive with an unvalidated argument. A
# report that arrives after the round was torn down used to raise "Invalid
# index" on the host.
func _check_setup_report_guard() -> void:
	_main.game.players_alive.clear()
	_main.game.players_setup.clear()
	_main.game._finished_game_setup(4242)
	_check("a setup report for an unknown peer is ignored",
		_main.game.players_setup.size(), 0)

# player_ready() used to tally the peer id inside the message, so one client
# could mark everyone ready and force the round to start.
func _check_ready_tally() -> void:
	var my_id: int = get_tree().get_multiplayer().get_unique_id()

	# The status labels are looked up by node name, so give them something to
	# find before poking the RPC.
	_main.ready_screen.add_player(my_id, "Me")
	_main.ready_screen.add_player(7, "Someone else")

	_main.players_ready.clear()
	_main.player_ready(7)

	_check("player_ready ignores the peer id in the message",
		_main.players_ready.has(7), false)
	_check("player_ready tallies the sender", _main.players_ready.has(my_id), true)
	_check("one call marks exactly one player ready", _main.players_ready.size(), 1)

	_main.players_ready.clear()
	_main.ready_screen.clear_players()

# Local play called show_winner() with only a name, so score/is_match defaulted
# to 0/false forever: no scoreboard, and no way to win a couch match.
func _check_local_scoring() -> void:
	_main.game.get_game_settings().rounds_to_win = 2
	_main.players_score.clear()

	GameState.online_play = false
	_main._on_TitleScreen_play_local()
	await get_tree().process_frame
	_check_true("local play started", _main.game.game_started)

	_main._on_game_over_signal(1)
	_check("a local round win is recorded", int(_main.players_score.get(1, 0)), 1)

	await get_tree().create_timer(ROUND_GAP).timeout
	_check_true("the next local round starts", _main.game.game_started)
	_check("the score survives the round restart", int(_main.players_score.get(1, 0)), 1)

	_main._on_game_over_signal(1)
	_check("the winning round reaches rounds_to_win", int(_main.players_score.get(1, 0)), 2)

	await get_tree().create_timer(ROUND_GAP).timeout
	_check("a local match can actually be won", _main.game.game_started, false)
	_check("the scoreboard resets after a local match", _main.players_score.size(), 0)
	_check_true("a won local match returns to the menu", _screen_visible("TitleScreen"))

# Abandoning a match went straight to the match screen without stop_game(), so
# players_score leaked into the next match and the abandoned round kept running.
func _check_teardown_resets_score() -> void:
	GameState.online_play = false
	_main._on_TitleScreen_play_local()
	await get_tree().process_frame

	_main.players_score[1] = 3
	_main._on_OnlineMatch_error("something went wrong")

	_check("teardown clears the scoreboard", _main.players_score.size(), 0)
	_check("teardown stops the round", _main.game.game_started, false)
	_check("teardown clears the roster", _main.players.size(), 0)
	_check_true("teardown shows the match screen", _screen_visible("MatchScreen"))
	_check("teardown leaves the tree running", get_tree().paused, false)

# When a peer leaves, the authority of its player node is exactly the peer that
# is gone, so die() -- which is gated on is_multiplayer_authority() -- did
# nothing on every remaining machine: the body kept walking, was invulnerable,
# and players_alive never lost the key, so the round could never end.
func _check_departed_player_is_removed() -> void:
	GameState.online_play = false
	_main._on_TitleScreen_play_local()
	await get_tree().process_frame

	var victim: Node = _main.game.players_node.get_node_or_null("1")
	_check_true("a player node exists for peer 1", victim != null)
	if victim == null:
		return

	# A third entry keeps the round from ending, so these assertions are about
	# kill_player() alone.
	_main.game.players_alive[99] = "Ghost"

	# No frame boundary while online_play is true: a physics tick would try to
	# broadcast player state through a multiplayer peer this test does not have.
	GameState.online_play = true
	victim.set_multiplayer_authority(7)
	_main.game.kill_player(1)
	GameState.online_play = false

	_check("kill_player removes a departed peer's player",
		_main.game.players_alive.has(1), false)
	_check_true("the departed player's node is really gone",
		victim.is_queued_for_deletion())

	_main.game.players_alive.erase(99)

# A whole four-player match, start to finish.
#
# Everything below is covered piecemeal elsewhere -- seats, the scoreboard, the
# countdown, the map bag, scoring, the match end -- but they only ever meet each
# other in a real match, and that is where the ordering between them can be
# wrong without any single unit failing. Rounds here are decided by calling
# _on_game_over_signal directly rather than by playing them out, so the test is
# about the machinery around a round rather than about combat.
func _check_four_player_match() -> void:
	_main.stop_game()
	await get_tree().process_frame

	_main.game.get_game_settings().rounds_to_win = 3
	_main.game.get_game_settings().round_countdown = 0.0
	_main.players_score.clear()

	GameState.online_play = false
	_main._on_TitleScreen_play_local(4)
	await get_tree().process_frame

	var seats := 0
	for child in _main.game.players_node.get_children():
		if child.has_method("pickup_or_throw"):
			seats += 1
	_check("a four-player match seats four", seats, 4)

	var hud = _main.ui_layer.hud
	_check("the scoreboard has all four", hud.player_count(), 4)
	_check_true("the scoreboard is up", hud.is_visible_in_tree())

	# Seat 2 takes the match; seat 3 takes one round on the way, so the test
	# proves the board tracks more than a single player.
	var maps_seen := {}
	var winners := [2, 3, 2, 2]
	var expected := {2: 0, 3: 0}

	for i in range(winners.size()):
		maps_seen[_main.game.map_index] = true

		var winner: int = winners[i]
		expected[winner] += 1
		_main._on_game_over_signal(winner)

		_check("round %d credits seat %d" % [i + 1, winner],
			int(_main.players_score.get(winner, 0)), expected[winner])

		# The board has to agree with the tally, every round, not just at the end.
		if hud.has_player(winner):
			_check("round %d shows on the scoreboard" % [i + 1],
				hud._score_of(winner), expected[winner])

		await get_tree().create_timer(ROUND_GAP).timeout

		if expected[winner] >= 3:
			break

	_check("the match ends when someone reaches rounds_to_win",
		_main.game.game_started, false)
	_check("winning the match clears the scoreboard", _main.players_score.size(), 0)
	_check_true("the scoreboard comes down with the match",
		not hud.is_visible_in_tree())
	_check_true("a won match returns to the menu", _screen_visible("TitleScreen"))

	# Three rounds were played, and the arena is drawn from a bag rather than
	# being the same one every time.
	_check_true("the match visited more than one arena (%d)" % maps_seen.size(),
		maps_seen.size() > 1)

	_main.game.get_game_settings().rounds_to_win = 5
