extends Node

# Records real gameplay to a numbered PNG sequence, for looking at how the game
# MOVES rather than how one frame of it looks.
#
# Still screenshots hide almost everything that matters about feel: squash and
# stretch, landing weight, how a jump arcs, whether a weapon swing reads, camera
# drift, animation popping. All of that only exists between frames.
#
# Why scripted input rather than a screen recorder: the players read the real
# Input singleton through components/InputBuffer.gd, so Input.action_press() is
# genuinely the same path a keyboard takes -- no compositor, no window manager,
# no dropped frames, and the same run every time.
#
# Captures on PHYSICS frames, not rendered ones. The game simulates at 60Hz and
# renders as fast as it can, so capturing per rendered frame would produce
# duplicate frames and a slow-motion recording that misrepresents the pacing.
#
#   godot --path . tools/Capture.tscn -- <outdir> <scenario> [frames] [WxH]

const MainScene := preload("res://Main.tscn")

var _out := "/tmp/ptg-capture"
var _scenario := "run"
var _frames := 120
var _size := Vector2i(640, 360)

var _main: Node
var _viewport: SubViewport

# frame -> [[action, pressed], ...]
func _timeline() -> Dictionary:
	match _scenario:
		# Stand, walk, jump, land. The bread and butter: if the squash and
		# stretch is wrong, it is wrong here.
		"run":
			return {
				10: [["player1_right", true]],
				45: [["player1_jump", true]],
				50: [["player1_jump", false]],
				95: [["player1_right", false]],
			}
		# A short hop versus a long drop, to compare landing weight.
		"drop":
			return {
				8:  [["player1_jump", true]],
				12: [["player1_jump", false]],
				40: [["player1_right", true]],
				60: [["player1_jump", true]],
				75: [["player1_jump", false]],
				110:[["player1_right", false]],
			}
		# Walk into a weapon, pick it up, swing it.
		"fight":
			return {
				10: [["player1_right", true]],
				70: [["player1_right", false]],
				# Grab repeatedly: a single press can miss if the pickup area has
				# not overlapped the weapon yet, and a scenario that quietly
				# fails to arm the player tests nothing.
				76: [["player1_grab", true]],
				79: [["player1_grab", false]],
				84: [["player1_grab", true]],
				87: [["player1_grab", false]],
				100:[["player1_use", true]],
				104:[["player1_use", false]],
				125:[["player1_use", true]],
				129:[["player1_use", false]],
			}
		# Handed a sword: swing standing, swing walking, then throw it.
		"sword":
			return {
				20: [["player1_use", true]], 24: [["player1_use", false]],
				55: [["player1_right", true]],
				70: [["player1_use", true]], 74: [["player1_use", false]],
				95: [["player1_right", false]],
				110: [["player1_grab", true]], 114: [["player1_grab", false]],
			}
		# Same for the grenade: carried, then thrown.
		"grenade":
			return {
				30: [["player1_right", true]],
				60: [["player1_grab", true]], 64: [["player1_grab", false]],
				90: [["player1_right", false]],
			}
		# Hold the draw, then loose: the bow only makes sense in motion.
		"bow":
			return {
				10: [["player1_grab", true]],
				13: [["player1_grab", false]],
				25: [["player1_use", true]],
				85: [["player1_use", false]],
			}
	return {}

# Some things are about the WEAPON, not about finding one. Walking to a
# generator and hoping the pickup area overlaps tests the arena layout; putting
# the weapon straight into the player's hands tests the weapon.
func _arm_player(scene_path: String) -> void:
	var players := []
	for child in _main.game.players_node.get_children():
		if child.has_method("pickup_or_throw"):
			players.append(child)
	if players.is_empty():
		return
	var p = players[0]
	var weapon = load(scene_path).instantiate()
	_main.game.map.add_child(weapon)
	await get_tree().process_frame
	weapon.global_position = p.global_position
	weapon.pickup_state = Pickup.PickupState.PICKED_UP
	weapon.pickup(p)
	weapon.get_parent().remove_child(weapon)
	var slot = p.back_pickup_position if weapon.pickup_position == Pickup.PickupPosition.BACK else p.front_pickup_position
	slot.add_child(weapon)
	weapon.position = -weapon.held_position.position
	p.current_pickup = weapon
	p.current_pickup_position = slot

# One line of ground truth per physics frame. What the player IS, alongside the
# frame that shows what they LOOK like -- a mismatch between the two is what a
# feel bug actually is.
func _sample(frame: int) -> String:
	var row := {"f": frame}
	var players := []
	for child in _main.game.players_node.get_children():
		if child.has_method("pickup_or_throw"):
			players.append(child)
	players.sort_custom(func(a, b): return str(a.name) < str(b.name))

	var out := []
	for p in players:
		var held = p.current_pickup
		var entry := {
			"id": str(p.name),
			"state": str(p.state_machine.current_state.name) if p.state_machine.current_state else "-",
			"anim": str(p.get_current_animation()),
			"x": snappedf(p.global_position.x, 0.1),
			"y": snappedf(p.global_position.y, 0.1),
			"vx": snappedf(p.vector.x, 0.1),
			"vy": snappedf(p.vector.y, 0.1),
			"floor": p.is_on_floor(),
			"wall": p.is_on_wall(),
			"blocked": p.jump_blocked,
			"sqx": snappedf(p._squash.x, 0.01),
			"sqy": snappedf(p._squash.y, 0.01),
			"flip": p.flip_h,
			"held": (held.get_script().resource_path.get_file() if held and held.get_script() else ""),
		}
		if held != null:
			var hb = held.get_node_or_null("Hitbox")
			if hb != null:
				entry["hb"] = not hb.disabled
		out.append(entry)
	row["p"] = out
	return JSON.stringify(row)

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: _out = args[0]
	if args.size() > 1: _scenario = args[1]
	if args.size() > 2: _frames = int(args[2])
	if args.size() > 3:
		var p := args[3].split("x")
		if p.size() == 2: _size = Vector2i(int(p[0]), int(p[1]))

	DirAccess.make_dir_recursive_absolute(_out)
	# Render and simulation in step, so one captured frame is one tick.
	Engine.max_fps = 60

	_viewport = SubViewport.new()
	_viewport.size = _size
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.handle_input_locally = false
	add_child(_viewport)

	_main = MainScene.instantiate()
	_viewport.add_child(_main)
	await get_tree().process_frame
	await get_tree().process_frame

	GameState.online_play = false
	# No count-in: the recording should open on the fight, not on a number.
	_main.game.get_game_settings().round_countdown = 0.0
	_main._on_TitleScreen_play_local(2)
	await get_tree().process_frame
	_main.ui_layer.hide_all()
	_main._refresh_hud()

	match _scenario:
		"sword": await _arm_player("res://pickups/Sword.tscn")
		"grenade": await _arm_player("res://pickups/Grenade.tscn")

	var timeline := _timeline()
	var log_lines := PackedStringArray()
	for f in range(_frames):
		if timeline.has(f):
			for entry in timeline[f]:
				if entry[1]:
					Input.action_press(entry[0])
				else:
					Input.action_release(entry[0])
		await get_tree().physics_frame
		log_lines.append(_sample(f))
		# One extra frame so the render reflects the physics tick just taken.
		await RenderingServer.frame_post_draw
		_viewport.get_texture().get_image().save_png("%s/f%04d.png" % [_out, f])

	# Leave no action stuck down for whatever runs next.
	for a in ["player1_left", "player1_right", "player1_jump", "player1_grab", "player1_use"]:
		Input.action_release(a)

	var f := FileAccess.open("%s/telemetry.jsonl" % _out, FileAccess.WRITE)
	for line in log_lines:
		f.store_line(line)
	f.close()

	print("[capture] %s: %d frames -> %s" % [_scenario, _frames, _out])
	get_tree().quit(0)
