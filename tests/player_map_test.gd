extends Node

# Guards the Godot-3-port fixes in actors/Player.gd, pickups/Sword.gd and
# maps/Map.gd. Every one of these bugs parsed fine and only misbehaved (or
# errored) on the frame it ran, which is why they survived the port unnoticed.
#
# Runs headless with no server: it drives the nodes directly.

const PlayerScene := preload("res://actors/Player.tscn")
const SwordScene := preload("res://pickups/Sword.tscn")
const Map1Scene := preload("res://maps/Map1.tscn")
const Map2Scene := preload("res://maps/Map2.tscn")
const InputBufferScript := preload("res://components/InputBuffer.gd")

# What get_map_rect() used to multiply every map's cell rect by.
const OLD_TILE_SIZE := Vector2(70, 70)

# Physics layer numbers as named in project.godot's [layer_names], 1-based, the
# way set_collision_mask_value()/get_collision_mask_value() count them.
const LAYER_ENVIRONMENT := 1
const LAYER_PICKUP := 4
const LAYER_ONE_WAY_PLATFORMS := 5

var _failures := 0

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[player] OK: %s" % label)
	else:
		_failures += 1
		print("[player] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _check_near(label: String, actual: float, expected: float, tolerance: float = 0.5) -> void:
	if absf(actual - expected) <= tolerance:
		print("[player] OK: %s" % label)
	else:
		_failures += 1
		print("[player] FAIL: %s (expected ~%s, got %s)" % [label, str(expected), str(actual)])

func _ready() -> void:
	print("[player] starting")

	await _check_one_way_platform_mask()
	await _check_invincible()
	await _check_pickup_ignores_non_pickups()
	await _check_force_remove()
	_check_remote_input_edges()
	await _check_sword_throw_cancels_swing()
	await _check_map_rects()

	print("[player] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

func _make_player() -> CharacterBody2D:
	var holder := Node2D.new()
	add_child(holder)
	var player: CharacterBody2D = PlayerScene.instantiate()
	holder.add_child(player)
	return player

# ---------------------------------------------------------------------------
# Bug 1: one-way platform drop-through toggled the wrong physics layer.
#
# Godot 3's set_collision_mask_bit() was 0-indexed and Godot 4's
# set_collision_mask_value() is 1-indexed, so the ported constant of 4 poked
# layer 4 ("Pickup"), which is not even in the player's mask of 17.
# ---------------------------------------------------------------------------
func _check_one_way_platform_mask() -> void:
	var player := _make_player()
	await get_tree().physics_frame

	_check("constant names the 1-based OneWayPlatforms layer",
		player.ONE_WAY_PLATFORMS_COLLISION_LAYER, LAYER_ONE_WAY_PLATFORMS)

	# Starting state, straight out of Player.tscn (collision_mask = 17).
	_check_true("collides with Environment to start",
		player.get_collision_mask_value(LAYER_ENVIRONMENT))
	_check_true("collides with OneWayPlatforms to start",
		player.get_collision_mask_value(LAYER_ONE_WAY_PLATFORMS))

	player.pass_through_one_way_platforms = true
	_check("ducking clears the OneWayPlatforms bit",
		player.get_collision_mask_value(LAYER_ONE_WAY_PLATFORMS), false)
	_check_true("ducking keeps colliding with Environment",
		player.get_collision_mask_value(LAYER_ENVIRONMENT))
	_check("ducking does not touch the Pickup layer",
		player.get_collision_mask_value(LAYER_PICKUP), false)

	player.pass_through_one_way_platforms = false
	_check_true("standing restores the OneWayPlatforms bit",
		player.get_collision_mask_value(LAYER_ONE_WAY_PLATFORMS))
	_check("mask is back to its scene value", player.collision_mask, 17)

	player.get_parent().queue_free()

# ---------------------------------------------------------------------------
# Bug 4: `invincible` was exported but never read.
# ---------------------------------------------------------------------------
func _check_invincible() -> void:
	var player := _make_player()
	await get_tree().physics_frame

	var damage_source := Node2D.new()
	add_child(damage_source)
	damage_source.global_position = player.global_position + Vector2(20, 0)

	player.invincible = true
	player.hurt(damage_source)
	_check("invincible player is not hurt",
		player.state_machine.current_state.name, "Idle")

	player.invincible = false
	player.hurt(damage_source)
	_check("vulnerable player is hurt",
		player.state_machine.current_state.name, "Hurt")

	damage_source.queue_free()
	player.get_parent().queue_free()

# ---------------------------------------------------------------------------
# Bug 2: _try_pickup() called can_pickup() on whatever the PickupArea reported.
#
# Map1's inline TileSet puts terrain on every physics layer, so a TileMap came
# back from get_overlapping_bodies() and the unguarded call raised "Nonexistent
# function 'can_pickup' in base 'TileMap'", aborting the loop before the weapon
# lying next to the wall was ever reached.
#
# Stand-in for the terrain: a body on the Pickup layer that has no can_pickup().
# (A bare StaticBody2D is not reported by Area2D.get_overlapping_bodies() in a
# headless run, so AnimatableBody2D -- also a static body -- is used instead.)
# ---------------------------------------------------------------------------
func _check_pickup_ignores_non_pickups() -> void:
	var player := _make_player()
	var holder := player.get_parent()
	player.global_position = Vector2.ZERO

	var terrain := AnimatableBody2D.new()
	terrain.name = "Terrain"
	terrain.collision_layer = 1 << (LAYER_PICKUP - 1)
	var terrain_shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(64, 64)
	terrain_shape.shape = rect
	terrain.add_child(terrain_shape)
	holder.add_child(terrain)
	terrain.global_position = Vector2(0, -14)
	_check("the stand-in terrain body has no can_pickup()",
		terrain.has_method("can_pickup"), false)

	var sword: CharacterBody2D = SwordScene.instantiate()
	holder.add_child(sword)
	sword.global_position = Vector2.ZERO

	# Let the PickupArea register both overlaps.
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

	var overlapping: Array = player.pickup_area.get_overlapping_bodies()
	_check_true("the non-pickup body really is reported by PickupArea",
		overlapping.has(terrain))
	_check_true("the sword is reported by PickupArea", overlapping.has(sword))

	# The bug: this errored out instead of picking the sword up.
	player._try_pickup()
	_check("weapon is picked up despite a non-pickup body being in range",
		player.current_pickup, sword)

	holder.queue_free()

# ---------------------------------------------------------------------------
# Cross-track contract: force_remove() removes a player whose owning peer has
# gone away, with no authority gate and no RPC.
# ---------------------------------------------------------------------------
func _check_force_remove() -> void:
	var player := _make_player()
	var holder := player.get_parent()
	await get_tree().physics_frame

	_check_true("Player exposes force_remove()", player.has_method("force_remove"))

	var dead := [false]
	player.player_dead.connect(func(): dead[0] = true)

	# Authority belongs to a peer that is not us, exactly as it would after that
	# peer dropped out of the match.
	player.set_multiplayer_authority(4242, false)
	player.force_remove()

	_check_true("force_remove() emits player_dead", dead[0])
	_check_true("force_remove() frees the node", player.is_queued_for_deletion())

	# Calling it twice must not double up the explosion or the signal.
	dead[0] = false
	player.force_remove()
	_check("force_remove() is idempotent", dead[0], false)

	await get_tree().physics_frame
	holder.queue_free()

# ---------------------------------------------------------------------------
# Bug 6: whole-buffer replace dropped edge-triggered remote inputs.
#
# A tap sends two packets one frame apart (edge set, then edge cleared). Both
# can land in the same MultiplayerAPI poll, and the old
# `input_buffer.buffer = _input_buffer` wiped the edge before any physics frame
# saw it, so the remote player silently missed the jump.
# ---------------------------------------------------------------------------
func _packet(jump_just_pressed: bool, jump_pressed: bool) -> Dictionary:
	var buffer := {}
	for action in ["left", "right", "down", "jump", "grab", "use", "blop"]:
		buffer[action] = {
			InputBufferScript.ActionType.PRESSED: false,
			InputBufferScript.ActionType.JUST_PRESSED: false,
			InputBufferScript.ActionType.JUST_RELEASED: false,
			InputBufferScript.ActionType.STRENGTH: 0.0,
		}
	buffer["jump"][InputBufferScript.ActionType.PRESSED] = jump_pressed
	buffer["jump"][InputBufferScript.ActionType.JUST_PRESSED] = jump_just_pressed
	return buffer

func _check_remote_input_edges() -> void:
	var player: CharacterBody2D = PlayerScene.instantiate()
	player.input_buffer = InputBufferScript.new(player.PlayerActions, player.input_prefix)

	# Two packets delivered back to back, with no physics frame in between.
	player._apply_remote_input(_packet(true, true))
	player._apply_remote_input(_packet(false, true))
	_check_true("an unconsumed just_pressed survives a second packet",
		player.input_buffer.is_action_just_pressed("jump"))
	_check_true("the held state still comes from the newest packet",
		player.input_buffer.is_action_pressed("jump"))

	# A physics frame consumes the edge; predict_next_frame() clears it.
	player.input_buffer.predict_next_frame()
	player.remote_input_pending = false

	player._apply_remote_input(_packet(false, true))
	_check("a consumed just_pressed does not stick",
		player.input_buffer.is_action_just_pressed("jump"), false)

	player.free()

# ---------------------------------------------------------------------------
# Bug 3: Sword._on_throw() played a "Reset" animation that does not exist, so
# the swing kept running and a sword thrown mid-swing kept a live hitbox.
# ---------------------------------------------------------------------------
func _check_sword_throw_cancels_swing() -> void:
	var holder := Node2D.new()
	add_child(holder)
	var sword: CharacterBody2D = SwordScene.instantiate()
	holder.add_child(sword)
	await get_tree().physics_frame

	var animation_player: AnimationPlayer = sword.animation_player
	var hitbox: Area2D = sword.hitbox
	_check_true("sword has a Hitbox node", hitbox != null)
	_check("Sword.tscn still has no Reset animation",
		animation_player.has_animation("Reset"), false)

	sword._do_use()
	# Advance into the window where Swing has the hitbox enabled (0.1s-0.2s).
	animation_player.seek(0.15, true)
	_check("swing enables the hitbox mid-animation", hitbox.disabled, false)

	sword.throw(Vector2.ZERO, Vector2(200, -100), 5.0)
	_check_true("throwing cancels the swing",
		animation_player.current_animation != "Swing")
	_check("thrown sword has no live hitbox", hitbox.disabled, true)

	holder.queue_free()

# ---------------------------------------------------------------------------
# Bug 5: get_map_rect() multiplied cell counts by a hard-coded 70x70 (the cell
# size of the art the game shipped with before the tileset swap) and ignored the
# node transforms, so the camera limits were several times too large and offset
# from the level.
# ---------------------------------------------------------------------------
func _tilemaps(map: Node2D) -> Array:
	var result := []
	for child in map.get_children():
		if child is TileMap:
			result.append(child)
	return result

func _old_map_rect(map: Node2D) -> Rect2:
	var rect: Rect2
	var found := false
	for tilemap in _tilemaps(map):
		if not found:
			rect = Rect2(tilemap.get_used_rect())
			found = true
		else:
			rect = rect.merge(Rect2(tilemap.get_used_rect()))
	return Rect2(rect.position * OLD_TILE_SIZE, rect.size * OLD_TILE_SIZE)

func _check_map_rects() -> void:
	var map1: Node2D = Map1Scene.instantiate()
	add_child(map1)
	await get_tree().process_frame

	var tilemaps := _tilemaps(map1)
	_check("Map1 has two TileMaps", tilemaps.size(), 2)

	# Map1's inline TileSet declares no tile_size, so its cells are Godot's
	# 16x16 default -- not 70x70, and not the 30x30 of the shared tileset.
	_check("Map1's TileSet uses the 16x16 default",
		tilemaps[0].tile_set.tile_size, Vector2i(16, 16))

	# Map1's OneWayPlatforms lost its tile_set in the port: it still holds tile
	# data but can neither draw nor collide, so it is excluded from the bounds.
	# Give it a TileSet back and this assertion is what tells you to re-derive
	# the expected numbers below.
	_check("Map1's OneWayPlatforms still has no TileSet",
		tilemaps[1].tile_set, null)

	# Environment: used_rect (-3, -50) 87x54 cells at 16px = (-48, -800) 1392x864
	# local pixels, through Map1's transform (scale 1.36584 x 1.16304,
	# offset (61, -71)).
	var rect: Rect2 = map1.get_map_rect()
	_check_near("Map1 rect left", rect.position.x, -4.56)
	_check_near("Map1 rect top", rect.position.y, -1001.43, 1.0)
	_check_near("Map1 rect width", rect.size.x, 1901.25, 1.0)
	_check_near("Map1 rect height", rect.size.y, 1004.87, 1.0)

	# The old maths was 3-4x too big in both axes, which is why the camera never
	# actually hit a limit.
	var old_rect := _old_map_rect(map1)
	_check_true("old Map1 rect was far too wide", old_rect.size.x > rect.size.x * 3.0)
	_check_true("old Map1 rect was far too tall", old_rect.size.y > rect.size.y * 3.0)

	map1.queue_free()

	var map2: Node2D = Map2Scene.instantiate()
	add_child(map2)
	await get_tree().process_frame

	# Map2 uses the shared tileset, which does declare 30x30.
	var map2_tilemaps := _tilemaps(map2)
	_check("Map2's TileSet is 30x30",
		map2_tilemaps[0].tile_set.tile_size, Vector2i(30, 30))

	# NOTE: both of Map2's TileMaps are empty -- their tile_data was dropped in
	# commit 7808f3f -- so there is nothing to bound and the rect is degenerate.
	# That is a content problem in Map2.tscn, not a maths problem here; this
	# assertion exists so that restoring the tiles trips it and this test gets
	# real numbers for Map2.
	var map2_empty := true
	for tilemap in map2_tilemaps:
		var used: Rect2i = tilemap.get_used_rect()
		if used.size.x > 0 and used.size.y > 0:
			map2_empty = false
	_check_true("Map2's TileMaps are (still) empty -- see Map2.tscn", map2_empty)

	map2.queue_free()
