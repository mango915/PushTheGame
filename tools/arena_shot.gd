extends Node

# Screenshots of the generated arenas, for looking at a layout instead of
# reading its coordinates.
#
# MUST run windowed. --headless uses the dummy renderer and captures nothing.
#
#   godot --path . tools/ArenaShot.tscn -- <out.png> <arena.tscn> [mode] [scale]
#
#   mode  "map"  (default) the whole arena at once, rendered into a SubViewport
#                sized to the map itself. tests/Screenshot.tscn can only ever
#                capture the game's 640x360 viewport, which is a fifth of an
#                arena; this shows the level.
#         "game" a real local match on that arena, framed by the real camera.
#                Slower, but it proves Game.gd is happy with the scene.
#   scale  multiplier on the SubViewport size in "map" mode (default 1.0).

const MainScene := preload("res://Main.tscn")

var _out := "arena.png"
var _arena := "res://maps/Arena1.tscn"
var _mode := "map"
var _scale := 1.0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	if args.size() > 1:
		_arena = args[1]
	if args.size() > 2:
		_mode = args[2]
	if args.size() > 3:
		_scale = float(args[3])

	if _mode == "game":
		await _shoot_game()
	else:
		await _shoot_map()

func _shoot_map() -> void:
	var map: Node2D = load(_arena).instantiate()

	# Instanced before the SubViewport is sized, because get_map_rect() reads the
	# TileMaps and needs nothing else.
	var rect: Rect2 = map.get_map_rect()
	var size := Vector2i(rect.size * _scale)

	var sub := SubViewport.new()
	sub.size = size
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.transparent_bg = false
	add_child(sub)

	sub.add_child(map)

	var camera := Camera2D.new()
	camera.position = rect.position + rect.size * 0.5
	camera.zoom = Vector2(_scale, _scale)
	sub.add_child(camera)
	camera.make_current()

	for i in range(20):
		await get_tree().process_frame

	var image := sub.get_texture().get_image()
	_write(image)

func _shoot_game() -> void:
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame

	# Point the real Game node at the arena before the round is set up. This is
	# a runtime property assignment, not an edit to Game.gd or Game.tscn -- map
	# selection proper is being wired up separately.
	var game = main.get_node("Game")
	game.map_scene = load(_arena)

	main._on_TitleScreen_play_local()
	main.get_node("UILayer").hide_all()

	for i in range(120):
		await get_tree().process_frame

	_write(get_viewport().get_texture().get_image())

func _write(image: Image) -> void:
	DirAccess.make_dir_recursive_absolute(_out.get_base_dir())
	var err := image.save_png(_out)
	if err == OK:
		print("[shot] wrote %s (%dx%d)" % [_out, image.get_width(), image.get_height()])
	else:
		print("[shot] FAILED to write %s (error %d)" % [_out, err])
	get_tree().quit(0 if err == OK else 1)
