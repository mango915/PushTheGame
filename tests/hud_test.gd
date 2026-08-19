extends Node

# Guards three things that were all invisible-by-construction before.
#
# 1. UILayer/Overlay carried `visible = false` in Main.tscn and nothing ever
#    turned it back on, so every show_message() in the game rendered nothing and
#    the Back button -- the only way out of a match -- could not be clicked. No
#    assertion anywhere looked at it, because show_message() sets the LABEL's own
#    visible flag and that part worked fine. is_visible_in_tree() is the check
#    that catches a hidden ancestor.
#
# 2. Local play built a roster of exactly two, so the third and fourth seats
#    were unreachable even though every arena places four spawn markers.
#
# 3. The score was only ever on screen between rounds.

const MainScene := preload("res://Main.tscn")

var _failures := 0
var _main: Node

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[hud] OK: %s" % label)
	else:
		_failures += 1
		print("[hud] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[hud] booting Main.tscn")
	_main = MainScene.instantiate()
	add_child(_main)
	await get_tree().process_frame
	await get_tree().process_frame

	GameState.online_play = false
	OnlineMatch.leave()

	_check_overlay_is_reachable()
	await _check_local_player_counts()
	await _check_scoreboard()
	await _check_teardown()

	_main.stop_game()
	_main.queue_free()
	await get_tree().process_frame

	print("[hud] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

#####
# 1. The overlay
#####

func _check_overlay_is_reachable() -> void:
	var ui = _main.ui_layer
	var overlay: Control = ui.get_node("Overlay")
	var message: Control = ui.get_node("Overlay/Message")
	var back: Control = ui.get_node("Overlay/BackButton")

	_check_true("the overlay itself is visible", overlay.visible)

	# On the title screen the back button must be down -- but note UILayer._ready
	# shows TitleScreen BEFORE setting _is_ready, so change_screen never fires for
	# the first screen and Main never gets a chance to hide it. It has to default
	# hidden in the scene.
	_check("back button is hidden on the title screen", back.is_visible_in_tree(), false)
	_check("no message on the title screen", message.is_visible_in_tree(), false)

	ui.show_message("You lose!")
	_check_true("a shown message really reaches the screen", message.is_visible_in_tree())
	_check("the message says what it was given", message.text, "You lose!")

	ui.show_back_button()
	_check_true("a shown back button really reaches the screen", back.is_visible_in_tree())

	ui.hide_all()
	_check("hide_all takes the message down", message.is_visible_in_tree(), false)
	_check("hide_all takes the back button down", back.is_visible_in_tree(), false)

#####
# 2. Local seats
#####

func _players_in_round() -> Array:
	var found := []
	for child in _main.game.players_node.get_children():
		if child.has_method("pickup_or_throw"):
			found.append(child)
	return found

func _check_local_player_counts() -> void:
	for count in [2, 3, 4]:
		_main.stop_game()
		await get_tree().process_frame

		_main._on_TitleScreen_play_local(count)
		await get_tree().process_frame

		var spawned := _players_in_round()
		_check("%d-player local match spawns %d players" % [count, count],
			spawned.size(), count)

		# Each seat must be wired to its own input prefix, or two players share a
		# controller and the extra seats are decorative.
		var prefixes := {}
		for player in spawned:
			prefixes[player.input_prefix] = true
			_check_true("seat %s is locally controlled" % player.name,
				player.player_controlled)
		_check("%d seats get %d distinct input prefixes" % [count, count],
			prefixes.size(), count)

		# Distinct characters, so four whales are actually told apart.
		var skins := {}
		for player in spawned:
			skins[player.player_skin] = true
		_check("%d seats get %d distinct characters" % [count, count],
			skins.size(), count)

	# The selector on the title screen is what supplies that number.
	var title = _main.ui_layer.get_node("Screens/TitleScreen")
	var reported := []
	title.play_local.connect(func (n): reported.append(n))
	title.local_player_count = 3
	title._on_LocalButton_pressed()
	_check("the title screen reports its chosen count", reported, [3])

	# Out-of-range input must not build a roster the arenas cannot seat.
	_main.stop_game()
	await get_tree().process_frame
	_main._on_TitleScreen_play_local(9)
	await get_tree().process_frame
	_check("an absurd count is clamped to the seats that exist",
		_players_in_round().size(), 4)

#####
# 3. The scoreboard
#####

func _check_scoreboard() -> void:
	_main.stop_game()
	await get_tree().process_frame
	_main._on_TitleScreen_play_local(4)
	await get_tree().process_frame

	var hud = _main.ui_layer.hud
	_check_true("the hud exists", hud != null)
	_check_true("the hud is on screen during a round", hud.is_visible_in_tree())
	_check("one chip per player", hud.player_count(), 4)
	for seat in [1, 2, 3, 4]:
		_check_true("seat %d has a chip" % seat, hud.has_player(seat))

	# A round win has to show up immediately, not at the next ready screen.
	var before = hud._score_of(2)
	var score: int = _main._record_win(2)
	_check("_record_win returns the new total", score, 1)
	_check("the chip shows the new total", hud._score_of(2), before + 1)
	_check("the target is on the chip too",
		hud._chips[2].score_label.text,
		"1/%d" % _main.game.get_game_settings().rounds_to_win)

	# An eliminated player dims rather than vanishing, so the row does not
	# reflow mid-fight.
	_main._on_player_dead(3)
	_check("an eliminated player is dimmed", hud._chips[3].root.modulate.a < 1.0, true)
	_check("everyone else is untouched", hud._chips[1].root.modulate.a, 1.0)

	hud.reset_alive()
	_check("a new round brings them back", hud._chips[3].root.modulate.a, 1.0)

func _check_teardown() -> void:
	var hud = _main.ui_layer.hud
	_main.stop_game()
	await get_tree().process_frame
	_check("the hud goes away with the match", hud.is_visible_in_tree(), false)
	_check("teardown clears the scoreboard", _main.players_score.size(), 0)
