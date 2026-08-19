extends Node

# Headless smoke test. Boots the real Main.tscn, drives local 2-player mode for a
# while, then quits. Its value is not assertions -- it is that GDScript runtime
# errors ("Nonexistent function", "Invalid call", ...) get printed to stderr,
# where scripts/check.sh greps for them. Most bugs in this project are Godot 3
# API leftovers that only fail on the frame they finally execute.

const MainScene := preload("res://Main.tscn")

# Frames to run after starting local play. At 60hz this is ~10 seconds of game.
const RUN_FRAMES := 600

# Frame at which we kill a player, to force the round-end path (game_over_signal
# -> show_winner -> restart). That path is where several of this project's
# broken signal connections and Godot 3 API leftovers actually live, so the test
# is much weaker without it.
const KILL_FRAME := 240

var _main: Node
var _frames := 0
var _started := false
var _failures := 0

func _players_container() -> Node:
	var game := _main.get_node_or_null("Game")
	if game == null:
		return null
	return game.get_node_or_null("Players")

func _ready() -> void:
	print("[smoke] booting Main.tscn")
	_main = MainScene.instantiate()
	add_child(_main)

	# Let the scene finish its own _ready pass (UILayer shows TitleScreen)
	# before we drive it.
	await get_tree().process_frame
	await get_tree().process_frame

	print("[smoke] starting local play")
	GameState.online_play = false
	_main._on_TitleScreen_play_local()
	_started = true

func _physics_process(_delta: float) -> void:
	if not _started:
		return

	_frames += 1

	# Poke the players so movement, jumping and the state machine actually run
	# rather than idling. Deterministic pattern, no randomness.
	_drive_players()

	if _frames == KILL_FRAME:
		_kill_one_player()

	# Give the explosion a few frames to spawn, then assert on it. Checked once,
	# before the round restarts and clears the container.
	if _frames == KILL_FRAME + 5:
		_assert_single_explosion()

	if _frames == RUN_FRAMES - 1:
		_assert_no_overlapping_music()

	if _frames >= RUN_FRAMES:
		print("[smoke] %d assertion(s) failed" % _failures)
		print("[smoke] completed %d frames" % _frames)
		get_tree().quit(0)

func _fail(msg: String) -> void:
	_failures += 1
	print("[smoke] FAIL: %s" % msg)

# A single death must produce exactly one explosion. Two means a death effect is
# being spawned from two places.
func _assert_single_explosion() -> void:
	var players_node := _players_container()
	if players_node == null:
		return
	var explosions := 0
	for child in players_node.get_children():
		if child is CPUParticles2D:
			explosions += 1
	if explosions == 1:
		print("[smoke] OK: one explosion for one death")
	else:
		_fail("expected 1 explosion after a single death, found %d" % explosions)

# Only one music track may be audible at a time. More than one means a crossfade
# started a new song without ever stopping the old one.
func _assert_no_overlapping_music() -> void:
	var music := _main.get_node_or_null("Music")
	if music == null:
		return
	var playing := []
	for child in music.get_children():
		if child is AudioStreamPlayer and child.playing:
			playing.append("%s(%.1fdB)" % [child.name, child.volume_db])
	if playing.size() <= 1:
		print("[smoke] OK: %d music track(s) playing" % playing.size())
	else:
		_fail("%d music tracks playing at once: %s" % [playing.size(), ", ".join(playing)])

func _kill_one_player() -> void:
	var players_node := _players_container()
	if players_node == null:
		return
	var alive := _actual_players(players_node)
	if alive.is_empty():
		return
	var victim: Node = alive[alive.size() - 1]
	print("[smoke] killing player %s to force round end" % victim.name)
	# Go through the state machine rather than calling die() directly, so this
	# follows the same path a real death takes (Dead._state_enter -> host.die()).
	# Calling die() directly would skip the Dead state and hide any effects it
	# spawns.
	victim.state_machine.change_state("Dead")

# The Players node holds more than players: death explosions are parented into
# it too (see Player._do_die), so filter to real player nodes.
func _actual_players(players_node: Node) -> Array:
	var result := []
	for child in players_node.get_children():
		if child.has_method("pickup_or_throw"):
			result.append(child)
	return result

func _drive_players() -> void:
	var players_node := _players_container()
	if players_node == null:
		return

	for player in _actual_players(players_node):
		if player.input_buffer == null:
			continue
		# Alternate walking left/right and jumping periodically, so Idle, Move,
		# Jump and Fall states all get exercised.
		var walk_right := (_frames / 60) % 2 == 0
		_set_action(player, "right", walk_right)
		_set_action(player, "left", not walk_right)
		_set_action(player, "jump", _frames % 45 == 0)
		_set_action(player, "grab", _frames % 90 == 0)
		_set_action(player, "use", _frames % 120 == 0)

func _set_action(player: Node, action: String, pressed: bool) -> void:
	var buffer = player.input_buffer.buffer
	if not buffer.has(action):
		return
	var was_pressed: bool = buffer[action][InputBufferScript.ActionType.PRESSED]
	buffer[action][InputBufferScript.ActionType.PRESSED] = pressed
	buffer[action][InputBufferScript.ActionType.JUST_PRESSED] = pressed and not was_pressed
	buffer[action][InputBufferScript.ActionType.JUST_RELEASED] = was_pressed and not pressed
	buffer[action][InputBufferScript.ActionType.STRENGTH] = 1.0 if pressed else 0.0

const InputBufferScript = preload("res://components/InputBuffer.gd")
