extends Node

# Screenshot tool for the sudden-death tide, for looking at the hazard without
# waiting 90 seconds for the round clock to expire.
#
# Must run WINDOWED (not --headless): headless uses a dummy renderer and
# captures nothing.
#
# Usage:
#   godot --path . tests/SuddenDeathShot.tscn -- <out.png> [progress] [frames]
#
#   progress  0..1, how far up the map the tide has risen (default 0.45).
#   frames    how many frames to settle before capturing (default 60).
#
# Deliberately not named *Test.tscn: scripts/check.sh globs that pattern for the
# unit gate, and this scene draws rather than asserts.

const MainScene := preload("res://Main.tscn")

var _out := "sudden_death.png"
var _progress := 0.45
var _frames := 60

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_progress = float(args[1])
	if args.size() > 2:
		_frames = int(args[2])

	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	GameState.online_play = false
	main._on_TitleScreen_play_local()
	await get_tree().process_frame

	var game = main.game

	# Run the clock out immediately rather than waiting for it, then hold the
	# tide at the requested height so the shot is reproducible.
	game._process(game.get_game_settings().round_time_limit)
	if game._sudden_death_zone != null:
		# Freeze the whole clock before posing the tide. Clearing
		# sudden_death_active instead would put Game._process back on the
		# countdown branch, which -- already at zero -- simply restarts sudden
		# death and resets the tide to the bottom.
		game.round_clock_running = false
		game._sudden_death_zone.set_progress(_progress)

	for i in range(_frames):
		await get_tree().process_frame

	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(_out)
	if err == OK:
		print("[shot] wrote %s (%dx%d)" % [_out, image.get_width(), image.get_height()])
	else:
		print("[shot] FAILED to write %s (error %d)" % [_out, err])

	get_tree().quit(0 if err == OK else 1)
