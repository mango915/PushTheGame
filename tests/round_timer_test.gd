extends Node

# The round clock and sudden death.
#
# Rounds used to be able to stall forever. The clock bounds them, and when it
# expires a rising kill zone makes the arena lethal until one player is left.
# Three things make this worth an explicit suite:
#
#   - Nothing errors when it goes wrong. A clock that survives a round just
#     makes the NEXT round short; a hazard left in the tree just kills the
#     winner during the victory message. Both look like gameplay, not bugs, and
#     this codebase has shipped exactly that class of leak before (scores
#     between matches, rounds simulating behind menus).
#   - The clock is host-authoritative, so its numbers travel through
#     GameSettings.to_dict()/from_dict(). A field missing from that round trip
#     means peers run different round lengths and drift with no error anywhere.
#   - Sudden death has to RESOLVE. If the tide stops short of the top of the
#     map, two campers survive it and the round stalls anyway -- which is the
#     entire problem it exists to fix.
#
# The clock is driven DIRECTLY (_advance_clock below pauses the tree and calls
# Game._process with an exact delta) rather than by waiting. A suite that slept
# 90 real seconds for a round timer would be useless, and one that measured
# whatever the engine happened to tick would be measuring the harness.

const MainScene := preload("res://Main.tscn")

var _failures := 0
var _main: Node
var _game: Node
var _ui: UILayer

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[timer] OK: %s" % label)
	else:
		_failures += 1
		print("[timer] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _check_near(label: String, actual: float, expected: float, tolerance: float = 0.01) -> void:
	if absf(actual - expected) <= tolerance:
		print("[timer] OK: %s" % label)
	else:
		_failures += 1
		print("[timer] FAIL: %s (expected %s +/- %s, got %s)" % [
			label, str(expected), str(tolerance), str(actual)])

func _ready() -> void:
	print("[timer] starting")
	GameState.online_play = false
	OnlineMatch.leave()

	# These two need nothing but the resource.
	_check_settings()
	_check_time_formatting()

	_main = MainScene.instantiate()
	add_child(_main)
	await get_tree().process_frame
	await get_tree().process_frame

	_game = _main.game
	_ui = _main.ui_layer

	await _check_clock_starts_with_the_round()
	await _check_zero_limit_disables_the_clock()
	await _check_clock_resets_between_rounds()
	await _check_clock_resets_on_teardown()
	await _check_sudden_death_geometry()
	await _check_hud_visibility()
	await _check_sudden_death_kill_wins_the_round()

	GameState.online_play = false
	_main.stop_game()

	print("[timer] %d assertion(s) failed" % _failures)

	# Deferred deletions have to be flushed before quitting or the engine
	# reports objects still alive at exit -- see tests/effect_zone_test.gd.
	_main.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame

	get_tree().quit(0)

#####
# Helpers
#####

# Advances the round clock by an exact number of seconds.
#
# The tree is paused first so the engine's own _process does not add frames on
# top of the injected delta: the clock would then be measuring the harness's
# timing rather than the mechanic, which is precisely how a recent assertion
# ended up measuring one frame of gravity instead of a launch pad.
func _advance_clock(seconds: float, steps: int = 1) -> void:
	var tree := get_tree()
	var was_paused := tree.paused
	tree.paused = true
	for i in range(maxi(1, steps)):
		_game._process(seconds / float(maxi(1, steps)))
	tree.paused = was_paused

# Starts a fresh local round with a known clock.
func _start_round(limit: float, sudden_death_duration: float = 20.0) -> void:
	GameState.online_play = false
	_main.stop_game()
	await get_tree().process_frame

	# Mutated before start_game(), which serialises the settings and rebuilds
	# them on every peer -- the same path the host's numbers take online.
	_game.get_game_settings().round_time_limit = limit
	_game.get_game_settings().sudden_death_duration = sudden_death_duration
	# A round now counts in before it becomes playable, and the round clock
	# deliberately does not start until it does -- otherwise players lose the
	# first seconds of a round they cannot yet move in. This suite measures the
	# clock, so it takes the count-in out rather than being paced by it, the
	# same way every other round-driving test does.
	_game.get_game_settings().round_countdown = 0.0

	_main._on_TitleScreen_play_local()

#####
# Settings: the numbers have to reach every peer
#####

func _check_settings() -> void:
	var settings := GameSettings.new()

	# The shipped feel, pinned. 90s only fires on a genuinely stalled round;
	# 20s is how long the arena takes to become entirely lethal.
	_check("default round_time_limit", settings.round_time_limit, 90.0)
	_check("default sudden_death_duration", settings.sudden_death_duration, 20.0)

	# Adding fields must not have disturbed the existing tuning.
	_check("rounds_to_win is untouched", settings.rounds_to_win, 5)
	_check("speed is untouched", settings.speed, 350.0)
	_check("jump_speed is untouched", settings.jump_speed, 700.0)

	_check_true("round_time_limit replicates",
		GameSettings.FIELDS.has("round_time_limit"))
	_check_true("sudden_death_duration replicates",
		GameSettings.FIELDS.has("sudden_death_duration"))

	# This is the wire format between host and clients.
	settings.round_time_limit = 45.0
	settings.sudden_death_duration = 7.5
	var data := settings.to_dict()
	_check("to_dict carries the round limit", data.get("round_time_limit"), 45.0)
	_check("to_dict carries the sudden death duration",
		data.get("sudden_death_duration"), 7.5)

	var rebuilt := GameSettings.from_dict(data)
	_check("from_dict restores the round limit", rebuilt.round_time_limit, 45.0)
	_check("from_dict restores the sudden death duration",
		rebuilt.sudden_death_duration, 7.5)

	# 0 is the "disabled" sentinel and must survive the trip intact, otherwise a
	# host who turned the clock off would still have clients running one.
	settings.round_time_limit = 0.0
	_check("a disabled clock round-trips",
		GameSettings.from_dict(settings.to_dict()).round_time_limit, 0.0)

	# The shipped resource must agree with the script, or editing one of them
	# changes nothing.
	var shipped = load("res://resources/default_game_settings.tres")
	if shipped is GameSettings:
		_check("the shipped resource has the same round limit",
			shipped.round_time_limit, 90.0)
		_check("the shipped resource has the same sudden death duration",
			shipped.sudden_death_duration, 20.0)

func _check_time_formatting() -> void:
	_check("a minute and a half reads as 1:30", UILayer.format_round_time(90.0), "1:30")
	_check("seconds are zero padded", UILayer.format_round_time(65.0), "1:05")
	_check("under a minute has no leading minutes", UILayer.format_round_time(9.0), "0:09")
	# Rounded UP: 0:00 has to mean expired, not "most of a second left".
	_check("a part second still shows a second", UILayer.format_round_time(5.2), "0:06")
	_check("expired reads as 0:00", UILayer.format_round_time(0.0), "0:00")
	_check("negative time cannot leak through", UILayer.format_round_time(-4.0), "0:00")

#####
# The clock starts with the ROUND, not with setup
#####

func _check_clock_starts_with_the_round() -> void:
	# Nothing has started yet: sitting on the title screen must not be running a
	# round clock, and there must be no hazard in the tree.
	_check("no clock before a round starts", _game.round_clock_running, false)
	_check("no time on the clock before a round starts", _game.round_time_left, 0.0)
	_check("no sudden death hazard before a round starts",
		_game._sudden_death_zone, null)
	_check("the HUD is hidden on the title screen", _ui.is_round_timer_visible(), false)

	await _start_round(60.0)

	# Asserted with no frame in between: _do_game_start() is what starts the
	# clock, so it is at exactly the configured limit at that instant.
	_check("the round starts the clock", _game.round_clock_running, true)
	_check("the clock starts at the configured limit", _game.round_time_left, 60.0)
	_check("the round does not begin in sudden death", _game.sudden_death_active, false)

	await get_tree().process_frame
	_check_true("the HUD appears once the round is running", _ui.is_round_timer_visible())

	# The setup handshake pauses the tree for up to SETUP_TIMEOUT_SECONDS. If
	# the clock ticked through that, a slow peer could reach sudden death before
	# anyone had moved -- which is why it is started in _do_game_start() and not
	# in _do_game_setup().
	get_tree().paused = true
	var before: float = _game.round_time_left
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_check("a paused tree does not eat the countdown", _game.round_time_left, before)
	get_tree().paused = false

	# Driven directly, so this measures the clock and not the frame rate.
	_game.round_time_left = 60.0
	_advance_clock(25.0)
	_check_near("the clock counts down by the elapsed time", _game.round_time_left, 35.0)

	_advance_clock(10.0, 20)
	_check_near("many small steps count the same as one big one",
		_game.round_time_left, 25.0)

	_check("counting down is not sudden death yet", _game.sudden_death_active, false)
	_check("the HUD shows the remaining time", _ui.round_timer_label.text, "0:25")

#####
# 0 disables the whole feature
#####

func _check_zero_limit_disables_the_clock() -> void:
	await _start_round(0.0)

	_check("a zero limit leaves the clock stopped", _game.round_clock_running, false)
	_check("a zero limit leaves no time on the clock", _game.round_time_left, 0.0)

	await get_tree().process_frame
	_check("a zero limit hides the HUD", _ui.is_round_timer_visible(), false)

	# Far longer than any round: with the clock disabled this must do nothing at
	# all, least of all flood the arena.
	_advance_clock(1000.0, 10)
	_check("a disabled clock never reaches sudden death",
		_game.sudden_death_active, false)
	_check("a disabled clock spawns no hazard", _game._sudden_death_zone, null)
	_check("the round is still running", _game.game_started, true)

#####
# Nothing survives into the next round
#####

func _check_clock_resets_between_rounds() -> void:
	await _start_round(60.0)
	_advance_clock(45.0)
	_check_near("the clock has run down", _game.round_time_left, 15.0)

	# The between-rounds path: keeps the scoreboard, restarts the round.
	_main.restart_game()

	_check("the next round gets a full clock", _game.round_time_left, 60.0)
	_check("the next round's clock is running", _game.round_clock_running, true)

	# And a round that reached sudden death must not hand the tide on.
	_advance_clock(60.0)
	_check("sudden death began", _game.sudden_death_active, true)
	_check_true("the tide is in the tree", _game._sudden_death_zone != null)

	_main.restart_game()
	_check("the next round is not in sudden death", _game.sudden_death_active, false)
	_check("the tide does not survive into the next round",
		_game._sudden_death_zone, null)
	_check("the next round's clock is full again", _game.round_time_left, 60.0)

func _check_clock_resets_on_teardown() -> void:
	await _start_round(60.0)
	_advance_clock(58.0)
	_check("sudden death is armed", _game.sudden_death_active, false)
	_advance_clock(5.0)
	_check_true("the tide exists before teardown", _game._sudden_death_zone != null)

	# The abandoned-match path (Main._on_OnlineMatch_error, the Back button).
	_main.stop_game()

	_check("teardown stops the clock", _game.round_clock_running, false)
	_check("teardown clears the clock", _game.round_time_left, 0.0)
	_check("teardown ends sudden death", _game.sudden_death_active, false)
	_check("teardown removes the tide", _game._sudden_death_zone, null)

	await get_tree().process_frame
	_check("teardown hides the HUD", _ui.is_round_timer_visible(), false)

#####
# Sudden death: it has to cover the whole arena, and it has to do it in the
# same place on every peer
#####

func _check_sudden_death_geometry() -> void:
	await _start_round(60.0, 20.0)

	var map_rect: Rect2 = _game.map.get_map_rect()
	_check_true("the map reports a usable rect",
		map_rect.size.x > 0.0 and map_rect.size.y > 0.0)

	_advance_clock(60.0)
	_check("the clock expiring starts sudden death", _game.sudden_death_active, true)
	_check("the clock reads zero in sudden death", _game.round_time_left, 0.0)

	var tide = _game._sudden_death_zone
	_check_true("sudden death spawns a hazard", tide != null)
	if tide == null:
		return

	_check("the tide covers the map's rect", tide.map_rect, map_rect)
	_check_near("the tide starts at the bottom of the map",
		tide.get_water_line(), map_rect.end.y, 0.5)

	# Halfway through the sudden-death duration, halfway up the map. This is the
	# whole replication story: the tide's position is a pure function of the
	# elapsed time, so peers that only ever received "sudden death has begun"
	# still draw it in the same place.
	_advance_clock(10.0, 10)
	_check_near("the tide is halfway up at half the duration",
		tide.get_water_line(), map_rect.end.y - map_rect.size.y * 0.5, 1.0)

	# ...and identical when the same progress is reached any other way.
	var reference: float = tide.get_water_line()
	tide.set_progress(0.0)
	tide.set_progress(0.5)
	_check_near("the tide's position depends only on progress",
		tide.get_water_line(), reference, 0.01)

	# The lethal part really is where the drawing says it is.
	var top_of_shape: float = tide._zone.position.y - tide._shape.size.y * 0.5
	_check_near("the kill zone's top edge is the water line",
		top_of_shape, tide.get_water_line(), 0.01)
	_check_near("the kill zone spans the whole map width",
		tide._shape.size.x, map_rect.size.x, 0.01)

	# THE point of the mechanic: after sudden_death_duration there is nowhere
	# left to stand. Two campers in opposite corners are both under water.
	_advance_clock(10.0, 10)
	_check_near("the tide reaches the top of the map",
		tide.get_water_line(), map_rect.position.y, 1.0)
	_check("the tide stops at the top", tide.progress, 1.0)

	# Overrunning must not push it past the map either.
	_advance_clock(60.0)
	_check_near("the tide does not overshoot", tide.get_water_line(), map_rect.position.y, 1.0)

	_main.stop_game()
	await get_tree().process_frame

#####
# HUD
#####

func _check_hud_visibility() -> void:
	await _start_round(90.0)
	await get_tree().process_frame

	_check_true("the HUD is visible in a running round", _ui.is_round_timer_visible())

	_ui.set_round_time(90.0, true, false)
	_check("the HUD shows the full round length", _ui.round_timer_label.text, "1:30")

	_ui.set_round_time(30.0, true, false)
	_check("the HUD follows the clock", _ui.round_timer_label.text, "0:30")

	# A stopped clock means no round: between rounds, after a win, after
	# teardown.
	_ui.set_round_time(30.0, false, false)
	_check("a stopped clock hides the HUD", _ui.is_round_timer_visible(), false)

	# Menus and the lobby are both "a screen is up".
	_ui.show_screen("TitleScreen")
	_ui.set_round_time(30.0, true, false)
	_check("the HUD stays hidden on the title screen",
		_ui.is_round_timer_visible(), false)

	_ui.show_screen("ReadyScreen")
	_ui.set_round_time(30.0, true, false)
	_check("the HUD stays hidden in the lobby", _ui.is_round_timer_visible(), false)

	_ui.hide_screen()
	_ui.set_round_time(30.0, true, false)
	_check_true("the HUD returns once the screen is gone", _ui.is_round_timer_visible())

	_ui.set_round_time(0.0, true, true)
	_check("sudden death is spelled out on the HUD",
		_ui.round_timer_label.text, "SUDDEN DEATH")
	_check_true("the HUD is visible during sudden death", _ui.is_round_timer_visible())

	# hide_all() is what Main calls as a round starts; the HUD has to be part of
	# it, or it would linger from the previous round.
	_ui.hide_all()
	_check("hide_all takes the HUD with it", _ui.is_round_timer_visible(), false)

	# Position. The viewport is 640x360; the HUD sits in the strip above the
	# message label and between the two corner buttons. A HUD over the Back
	# button is worse than no HUD.
	_ui.set_round_time(90.0, true, false)
	await get_tree().process_frame

	var timer_rect: Rect2 = _ui.round_timer_label.get_global_rect()
	var viewport: Vector2 = Vector2(640, 360)
	_check_true("the HUD is inside the viewport",
		timer_rect.position.x >= 0.0 and timer_rect.position.y >= 0.0
		and timer_rect.end.x <= viewport.x and timer_rect.end.y <= viewport.y)
	_check_true("the HUD is horizontally centred",
		absf((timer_rect.position.x + timer_rect.end.x) * 0.5 - viewport.x * 0.5) < 1.0)

	_check("the HUD does not cover the message label",
		timer_rect.intersects(_ui.message_label.get_global_rect()), false)
	_check("the HUD does not cover the Back button",
		timer_rect.intersects(_ui.back_button.get_global_rect()), false)
	var mute := _ui.get_node_or_null("Overlay/MuteButton")
	if mute != null:
		_check("the HUD does not cover the Mute button",
			timer_rect.intersects(mute.get_global_rect()), false)

	_main.stop_game()
	await get_tree().process_frame

#####
# A sudden-death death is an ORDINARY death
#####

func _check_sudden_death_kill_wins_the_round() -> void:
	_main.players_score.clear()
	_game.get_game_settings().rounds_to_win = 5

	await _start_round(60.0, 20.0)
	await get_tree().process_frame

	_check("the round starts with two players", _game.players_alive.size(), 2)

	_advance_clock(60.0)
	_check("sudden death began", _game.sudden_death_active, true)

	# Jump straight to a fully flooded arena rather than waiting 20 real
	# seconds: both players are then inside the kill zone and the tide has to
	# resolve the round on its own.
	_game._sudden_death_elapsed = 10000.0
	_advance_clock(0.001)

	var waited := 0
	while _game.players_alive.size() > 1 and waited < 120:
		await get_tree().physics_frame
		waited += 1

	_check_true("the tide killed somebody", _game.players_alive.size() < 2)
	_check("the round is over", _game.game_over, true)

	# The edge case: the tide reaches both players at once. The round is decided
	# on the first death, which is also what switches the tide off, so exactly
	# one player is left standing rather than nobody.
	_check("exactly one player survives sudden death", _game.players_alive.size(), 1)

	# ...and that is an ordinary round win as far as Main is concerned.
	_check("a sudden-death win is scored like any other",
		_main.players_score.size(), 1)
	_check("the survivor is credited with one round",
		int(_main.players_score.values()[0]), 1)

	# Winning stops the clock and takes the hazard away, so the tide cannot keep
	# rising through the "X wins this round!" message and drown the winner too.
	_check("winning stops the clock", _game.round_clock_running, false)
	_check("winning ends sudden death", _game.sudden_death_active, false)
	_check("winning removes the tide", _game._sudden_death_zone, null)

	await get_tree().process_frame
	_check("the HUD disappears when the round is decided",
		_ui.is_round_timer_visible(), false)

	# show_winner() is mid-await on a 2s timer; stopping the game is what tells
	# its continuation there is no round left to restart.
	_main.stop_game()
	await get_tree().process_frame
