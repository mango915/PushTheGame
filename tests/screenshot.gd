extends Node

# Screenshot tool, for looking at the game without playing it.
#
# Must run WINDOWED (not --headless): headless uses a dummy renderer and
# captures nothing. The window still opens, it just quits by itself.
#
# Usage:
#   godot --path . tests/Screenshot.tscn -- <out.png> [screen] [frames] [WxH]
#
#   screen  a screen name under UILayer/Screens (TitleScreen, SettingsScreen,
#           MatchScreen, ...), or "localN" to start an N-player local match and
#           shoot the actual gameplay ("local", "local2".."local4").
#   frames  how many frames to settle before capturing (default 30).
#   WxH     output size (default 640x360, the project's design resolution).
#
# The scene is rendered into a SubViewport of exactly that size rather than
# captured from the window, because a tiling window manager hands the game
# whatever geometry it likes -- and with stretch/aspect = keep_width, a portrait
# window silently produces a tall viewport in which bottom-anchored UI sits far
# below the arena. Shooting a SubViewport makes the output identical everywhere.

const MainScene := preload("res://Main.tscn")

var _out := "screenshot.png"
var _target := "TitleScreen"
var _frames := 30
var _size := Vector2i(640, 360)

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_target = args[1]
	if args.size() > 2:
		_frames = int(args[2])
	if args.size() > 3:
		var parts := args[3].split("x")
		if parts.size() == 2:
			_size = Vector2i(int(parts[0]), int(parts[1]))

	var viewport := SubViewport.new()
	viewport.size = _size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.handle_input_locally = false
	add_child(viewport)

	var main = MainScene.instantiate()
	viewport.add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var ui_layer = main.get_node("UILayer")

	if _target.begins_with("local"):
		# Show the real thing: a running match, not a menu. A trailing digit
		# picks the seat count, so "local4" shoots a four-player couch match.
		var seats := 2
		var suffix := _target.substr(len("local"))
		if suffix.is_valid_int():
			seats = int(suffix)
		main._on_TitleScreen_play_local(seats)
		ui_layer.hide_all()
		main._refresh_hud()
	else:
		ui_layer.show_screen(_target)

	for i in range(_frames):
		await get_tree().process_frame

	var image := viewport.get_texture().get_image()
	var err := image.save_png(_out)
	if err == OK:
		print("[shot] wrote %s (%dx%d)" % [_out, image.get_width(), image.get_height()])
	else:
		print("[shot] FAILED to write %s (error %d)" % [_out, err])

	get_tree().quit(0 if err == OK else 1)
