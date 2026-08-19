extends Node

# Screenshot tool, for looking at the game without playing it.
#
# Must run WINDOWED (not --headless): headless uses a dummy renderer and
# captures nothing. The window still opens, it just quits by itself.
#
# Usage:
#   godot --path . tests/Screenshot.tscn -- <out.png> [screen] [frames]
#
#   screen  a screen name under UILayer/Screens (TitleScreen, SettingsScreen,
#           MatchScreen, ...), or "local" to start a local match and shoot the
#           actual gameplay.
#   frames  how many frames to settle before capturing (default 30).

const MainScene := preload("res://Main.tscn")

var _out := "screenshot.png"
var _target := "TitleScreen"
var _frames := 30

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_target = args[1]
	if args.size() > 2:
		_frames = int(args[2])

	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var ui_layer = main.get_node("UILayer")

	if _target == "local":
		# Show the real thing: a running match, not a menu.
		main._on_TitleScreen_play_local()
		ui_layer.hide_all()
	else:
		ui_layer.show_screen(_target)

	for i in range(_frames):
		await get_tree().process_frame

	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(_out)
	if err == OK:
		print("[shot] wrote %s (%dx%d)" % [_out, image.get_width(), image.get_height()])
	else:
		print("[shot] FAILED to write %s (error %d)" % [_out, err])

	get_tree().quit(0 if err == OK else 1)
