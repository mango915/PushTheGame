extends Node

# Guards the in-match pause menu (main/PauseMenu.gd).
#
# The two things most likely to break here are both about who owns the paused
# tree. The menu must not unpause a tree it did not pause -- the round countdown
# holds the tree too, and stealing it would start the round early -- and leaving
# a match must never hand back a paused tree, because a paused tree freezes the
# menu you are returning to.

const MainScene := preload("res://Main.tscn")

var _failures := 0
var _main: Node

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[pause] OK: %s" % label)
	else:
		_failures += 1
		print("[pause] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _set_countdown(seconds: float) -> void:
	# Rebuilt into a fresh instance by Game._do_game_setup every round, so this
	# has to be re-fetched rather than held.
	_main.game.get_game_settings().round_countdown = seconds

func _ready() -> void:
	print("[pause] booting Main.tscn")
	_main = MainScene.instantiate()
	add_child(_main)
	await get_tree().process_frame
	await get_tree().process_frame

	GameState.online_play = false
	OnlineMatch.leave()
	_set_countdown(0.0)

	_check_disabled_outside_a_match()
	await _check_local_pause()
	await _check_countdown_ownership()
	await _check_quit()
	await _check_online_does_not_pause()

	GameState.online_play = false
	_main.stop_game()
	_main.queue_free()
	await get_tree().process_frame

	print("[pause] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

func _menu() -> Control:
	return _main.ui_layer.pause_menu

func _check_disabled_outside_a_match() -> void:
	var menu := _menu()
	_check("pause is off on the menus", menu.enabled, false)
	_check("the pause menu starts hidden", menu.visible, false)

	# Sitting on the title screen, the pause key must do nothing at all.
	menu.toggle()
	_check_true("toggling still opens it if asked directly", menu.visible)
	menu.close()
	_check("...and closes again", menu.visible, false)
	_check("closing an unpaused tree leaves it running", get_tree().paused, false)

func _check_local_pause() -> void:
	_main._on_TitleScreen_play_local(2)
	await get_tree().process_frame

	var menu := _menu()
	_check_true("pause is armed once a round is running", menu.enabled)
	_check("the round starts unpaused", get_tree().paused, false)

	menu.open()
	_check_true("the menu is up", menu.visible)
	_check_true("local play really pauses", get_tree().paused)

	menu.close()
	_check("the menu is down", menu.visible, false)
	_check("closing resumes play", get_tree().paused, false)

	# Opening twice must not double-latch the tree.
	menu.open()
	menu.open()
	menu.close()
	_check("an already-open menu does not re-pause", get_tree().paused, false)

# The countdown holds the tree paused. A pause menu opened during it must hand
# the tree back to the countdown, not to the round.
func _check_countdown_ownership() -> void:
	_main.stop_game()
	await get_tree().process_frame
	_set_countdown(5.0)
	_main._on_TitleScreen_play_local(2)
	await get_tree().process_frame

	var menu := _menu()
	_check_true("the countdown has the tree paused", get_tree().paused)

	menu.open()
	_check_true("the menu opens over the countdown", menu.visible)
	_check_true("the tree is still paused", get_tree().paused)

	menu.close()
	_check_true("closing leaves the countdown's pause alone", get_tree().paused)

	# And the round still starts on its own afterwards.
	await get_tree().create_timer(5.6).timeout
	_check("the round begins once the count finishes", get_tree().paused, false)

	_main.stop_game()
	await get_tree().process_frame
	_set_countdown(0.0)

func _check_quit() -> void:
	_main.stop_game()
	await get_tree().process_frame
	_set_countdown(0.0)
	_main._on_TitleScreen_play_local(3)
	await get_tree().process_frame

	var menu := _menu()
	menu.open()
	_check_true("paused before quitting", get_tree().paused)

	menu._on_quit_pressed()
	await get_tree().process_frame

	_check("quitting closes the menu", menu.visible, false)
	_check("quitting never hands back a paused tree", get_tree().paused, false)
	_check("quitting stops the round", _main.game.game_started, false)
	_check("quitting disarms pause", menu.enabled, false)
	_check("quitting returns to a screen",
		_main.ui_layer.current_screen_name, "TitleScreen")

# Online has no such thing as pausing: the other peers keep playing, and halting
# our own simulation while their input keeps arriving would desync us silently.
func _check_online_does_not_pause() -> void:
	_main.stop_game()
	await get_tree().process_frame

	var menu := _menu()
	GameState.online_play = true
	menu.enabled = true

	menu.open()
	_check_true("the menu still opens online", menu.visible)
	_check("online play is NOT paused", get_tree().paused, false)
	_check_true("and it says so", menu._hint.text.contains("keeps running"))

	menu.close()
	_check("closing online leaves the tree running", get_tree().paused, false)

	GameState.online_play = false
	menu.enabled = false
