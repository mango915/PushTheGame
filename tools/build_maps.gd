extends SceneTree

# Arena generator for Push The Game.
#
#   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
#       --script res://tools/build_maps.gd
#
# Writes:
#   res://maps/arena_tileset.tres         terrain tiles  (physics layer 1)
#   res://maps/arena_oneway_tileset.tres  jump-through   (physics layer 5)
#   res://maps/Arena1.tscn                "Terrace"  1408 x 896
#   res://maps/Arena2.tscn                "The Well" 1216 x 960
#
# WHY A TOOL AND NOT HAND-WRITTEN .tscn
# ------------------------------------
# A TileMap stores its cells as a flat PackedInt32Array of bit-packed cell
# coordinates and atlas ids. It is not editable by hand with any confidence, and
# a single wrong int silently moves a platform. Building the scene in code with
# set_cell() and packing it means the layout below is the source of truth: retune
# a number, re-run, and both arenas are rebuilt and re-validated by
# tests/MapReachabilityTest.tscn.
#
# THE GRID
# --------
# The Kings & Pigs terrain art is drawn on a 32x32 grid but Map1's TileSet slices
# it into 16x16 cells (it declares no tile_size, so it gets Godot's 16x16
# default). Every piece of art is therefore a 2x2 block of cells. The layouts
# below are written in 32px BLOCKS and each block emits four cells, which keeps
# the 9-slice below working at the granularity the art was drawn at.
#
# MOVEMENT BUDGET (resources/default_game_settings.tres + project.godot)
# ---------------------------------------------------------------------
# gravity resolves to physics/2d/default_gravity = 1500 (the settings resource
# ships gravity = 0.0, the "use the project default" sentinel), NOT 980:
#     jump height   = 700^2 / (2*1500)  = 163 px  (5.1 blocks)
#     airtime       = 2*700 / 1500      = 0.93 s
#     jump distance = 350 * 0.93        = 327 px  (10.2 blocks)
#     launch pad    = 1150^2 / (2*1500) = 441 px  (13.8 blocks)
# Tiers are spaced 128 px (4 blocks) apart, 78% of the jump height, and same-level
# gaps are at most 192 px, 59% of the jump distance. The validator recomputes all
# of this from GameSettings and proves the result; these numbers are the intent.

const BLOCK := 32   # world px per design block
const CELL := 16    # world px per TileMap cell (2x2 cells per block)

const TERRAIN_TEXTURE := "res://assets/sprites/kings_and_pigs/14-TileSets/Terrain (32x32).png"
const MAP_SCRIPT := "res://maps/Map.gd"
const BACKGROUND_SCENE := "res://maps/StaticBackground.tscn"
const GENERATOR_SCENE := "res://objects/TimedGeneratorFlat.tscn"
const EFFECT_ZONE_SCRIPT := "res://objects/EffectZone.gd"
const GUN := "res://pickups/Gun.tscn"
const SWORD := "res://pickups/Sword.tscn"

const TERRAIN_TILESET_PATH := "res://maps/arena_tileset.tres"
const ONEWAY_TILESET_PATH := "res://maps/arena_oneway_tileset.tres"

# ---------------------------------------------------------------------------
# Atlas coordinates, as the TOP-LEFT cell of each 2x2 art tile.
#
# Map1's TileSet marks 188 of its 376 cells solid. Rows 2-7 of the atlas are a
# complete 3x3 nine-slice (its centre is opaque dark mortar, not a hole), rows
# 10-11 are a one-block-tall horizontal strip, and columns 10-11 are a
# one-block-wide vertical column. Together they cover all sixteen neighbour
# cases below, so any shape drawn in the layouts renders with proper caps and
# corners instead of a field of identical squares.
# ---------------------------------------------------------------------------
const T_TL := Vector2i(2, 2)
const T_T := Vector2i(4, 2)
const T_TR := Vector2i(6, 2)
const T_L := Vector2i(2, 4)
const T_C := Vector2i(4, 4)
const T_R := Vector2i(6, 4)
const T_BL := Vector2i(2, 6)
const T_B := Vector2i(4, 6)
const T_BR := Vector2i(6, 6)
const T_HLEFT := Vector2i(2, 10)    # horizontal strip: left cap
const T_HMID := Vector2i(4, 10)     #                   middle
const T_HRIGHT := Vector2i(6, 10)   #                   right cap
const T_VTOP := Vector2i(10, 2)     # vertical column:  top cap
const T_VMID := Vector2i(10, 4)     #                   middle
const T_VBOT := Vector2i(10, 6)     #                   bottom cap
const T_SINGLE := Vector2i(10, 10)  # isolated block

# The one-way TileSet reuses the horizontal strip, which is exactly the "thin
# platform you stand on" shape.
const OW_CELLS := [
	Vector2i(2, 10), Vector2i(3, 10), Vector2i(4, 10), Vector2i(5, 10),
	Vector2i(6, 10), Vector2i(7, 10),
	Vector2i(2, 11), Vector2i(3, 11), Vector2i(4, 11), Vector2i(5, 11),
	Vector2i(6, 11), Vector2i(7, 11),
]

var _failures := 0

func _initialize() -> void:
	print("[build] starting")

	var terrain := _build_terrain_tileset()
	if terrain == null:
		printerr("[build] FAILED: could not derive the terrain TileSet from Map1")
		quit(1)
		return
	_save(terrain, TERRAIN_TILESET_PATH)

	var oneway := _build_oneway_tileset()
	_save(oneway, ONEWAY_TILESET_PATH)

	# Reloaded from disk before the arenas are built. An in-memory resource has
	# no resource_path, and PackedScene.pack() inlines any such resource -- both
	# arenas would carry their own 60KB copy of the tileset instead of sharing
	# maps/arena_tileset.tres, and retuning a tile would then mean rebuilding
	# rather than editing one file.
	var terrain_shared: TileSet = load(TERRAIN_TILESET_PATH)
	var oneway_shared: TileSet = load(ONEWAY_TILESET_PATH)

	for spec in [arena1_spec(), arena2_spec()]:
		_build_arena(spec, terrain_shared, oneway_shared)

	print("[build] %d error(s)" % _failures)
	quit(1 if _failures > 0 else 0)

func _save(res: Resource, path: String) -> void:
	var err := ResourceSaver.save(res, path)
	if err != OK:
		_failures += 1
		printerr("[build] FAILED to save %s (error %d)" % [path, err])
	else:
		print("[build] wrote %s" % path)

# ---------------------------------------------------------------------------
# Tilesets
# ---------------------------------------------------------------------------

# Map1's TileSet is a sub-resource of Map1.tscn, so the only way to get at it is
# to instance the scene. It is resource_local_to_scene, hence the deep duplicate
# and the flag reset -- otherwise every arena that loaded the .tres would get its
# own private copy and the shared resource would be pointless.
#
# The one real fix applied here: Map1 ships physics_layer_0/collision_layer =
# 255, which puts terrain on EVERY layer including 4 ("Pickup"). The player's
# PickupArea has mask 8 and therefore reports every wall it touches as a pickup.
# Terrain belongs on layer 1 ("Environment") alone.
func _build_terrain_tileset() -> TileSet:
	var packed: PackedScene = load("res://maps/Map1.tscn")
	if packed == null:
		return null
	var map: Node2D = packed.instantiate()
	var env := map.get_node_or_null("Environment") as TileMap
	if env == null or env.tile_set == null:
		map.free()
		return null

	var ts: TileSet = env.tile_set.duplicate(true)
	map.free()

	ts.resource_local_to_scene = false

	# duplicate(true) is deep, so it also cloned the CompressedTexture2D -- and a
	# cloned texture has no resource_path, so saving the TileSet inlines it as a
	# sub-resource whose only pointer to the art is a load_path into
	# .godot/imported/. That cache path contains a content hash and is not
	# tracked by git, so the arenas would lose their tiles on any machine that
	# re-imported. Point the atlas back at the real .png.
	var texture: Texture2D = load(TERRAIN_TEXTURE)
	for si2 in range(ts.get_source_count()):
		var s2 := ts.get_source(ts.get_source_id(si2))
		if s2 is TileSetAtlasSource:
			(s2 as TileSetAtlasSource).texture = texture
	if ts.get_physics_layers_count() == 0:
		ts.add_physics_layer(0)
	ts.set_physics_layer_collision_layer(0, 1)  # Environment, and nothing else.
	ts.set_physics_layer_collision_mask(0, 0)   # Static terrain detects nothing.

	# The duplicate is only useful if it deep-copied the atlas source with its
	# collision polygons; a shallow copy would leave the arenas sharing Map1's
	# tiles and silently re-introduce collision_layer 255.
	var solid := 0
	for si in range(ts.get_source_count()):
		var src := ts.get_source(ts.get_source_id(si))
		if not (src is TileSetAtlasSource):
			continue
		var atlas: TileSetAtlasSource = src
		for ti in range(atlas.get_tiles_count()):
			var data := atlas.get_tile_data(atlas.get_tile_id(ti), 0)
			if data.get_collision_polygons_count(0) > 0:
				solid += 1
	print("[build] terrain tileset: %d source(s), %d solid tile(s), layer=%d" % [
		ts.get_source_count(), solid, ts.get_physics_layer_collision_layer(0)])
	if solid == 0:
		_failures += 1
		printerr("[build] FAILED: duplicated terrain TileSet has no solid tiles")
	return ts

# Built from scratch rather than derived, because nothing in the project has a
# working one-way tile: Map1's OneWayPlatforms TileMap lost its TileSet in the
# Godot 4 port and assets/tilesets/tileset.tres has no solid tiles at all.
#
# collision_layer 16 is layer 5, "OneWayPlatforms" -- the layer Player.tscn's
# collision_mask of 17 includes and that Player.set_pass_through_one_way_
# platforms() clears to duck-and-drop through.
#
# Collision goes on the TOP cell row only, so the 32px-tall art has a 16px band
# of collision along its upper edge and nothing below: "covering only the top of
# the tile". Godot's one-way direction for a tile shape is the shape transform's
# +Y, i.e. down, so the platform stops a body moving downward and ignores one
# moving up -- jump through from below, stand on top, duck+jump to drop off.
func _build_oneway_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(CELL, CELL)
	ts.add_physics_layer(0)
	ts.set_physics_layer_collision_layer(0, 16)
	ts.set_physics_layer_collision_mask(0, 0)

	var atlas := TileSetAtlasSource.new()
	atlas.texture = load(TERRAIN_TEXTURE)
	atlas.texture_region_size = Vector2i(CELL, CELL)
	# Attached to the TileSet FIRST. A TileSetAtlasSource only knows about the
	# physics layers of the TileSet that owns it, so tiles created while it is
	# detached have zero physics layers and every add_collision_polygon(0) below
	# fails with "p_layer_id = 0 is out of bounds" -- leaving a one-way tileset
	# that looks right and collides with nothing.
	ts.add_source(atlas, 1)

	var with_collision := 0
	for coords in OW_CELLS:
		atlas.create_tile(coords)
		if coords.y != 10:
			continue  # lower half of the art: decoration, no collision
		var data := atlas.get_tile_data(coords, 0)
		data.add_collision_polygon(0)
		data.set_collision_polygon_points(0, 0, PackedVector2Array([
			Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]))
		data.set_collision_polygon_one_way(0, 0, true)
		with_collision += 1

	print("[build] one-way tileset: %d tiles, %d with one-way collision, layer=%d" % [
		atlas.get_tiles_count(), with_collision,
		ts.get_physics_layer_collision_layer(0)])
	if with_collision == 0:
		_failures += 1
		printerr("[build] FAILED: one-way tileset has no collision")
	return ts

# ---------------------------------------------------------------------------
# Layouts
#
# Every rect is [col_from, row_from, col_to, row_to] in BLOCKS, inclusive.
# Row 0 is the top. A block at row R has its walkable top surface at y = R*32.
# ---------------------------------------------------------------------------

# ARENA 1 -- "Terrace": wide and layered. 44 x 28 blocks = 1408 x 896 px.
#
# Six full-width-ish tiers 128 px apart, three of which (T1, T2, T3) span the
# whole map, so players can circle horizontally at three different heights as
# well as climb. The centre is a stack -- island, catwalk, pad platform -- with
# an open shaft above it leading to a one-way "crow's nest" that ONLY the launch
# pad reaches. The floor has a hole in the middle over the kill void.
func arena1_spec() -> Dictionary:
	return {
		"name": "Arena1",
		"cols": 44,
		"rows": 28,
		"env_modulate": Color(1, 1, 1),
		"solid": [
			# Boundary. The floor is split to leave a pit at cols 20-23.
			[0, 0, 43, 0],      # ceiling
			[0, 1, 1, 25],      # left wall
			[42, 1, 43, 25],    # right wall
			[0, 26, 19, 27],    # floor, left of the pit
			[24, 26, 43, 27],   # floor, right of the pit

			# Two pillars: cover on the ground, and a stepping stone out of the
			# T1 gap above them. Nothing shorter goes on the ground floor --
			# a 1-block bump between a pillar and a wall makes a pocket that a
			# player in tar cannot jump out of, which the reachability test
			# rejects (correctly) as a trap.
			[14, 24, 15, 25],
			[28, 24, 29, 25],

			# T1, y=704: three long shelves with 128px gaps between them.
			[2, 22, 12, 22],
			[17, 22, 26, 22],
			[31, 22, 41, 22],

			# T2, y=576: the mid catwalk (one-way segments bridge the gaps).
			[2, 18, 9, 18],
			[19, 18, 24, 18],
			[34, 18, 41, 18],

			# T3, y=448: two plateaus and the narrow launch-pad platform.
			[5, 14, 15, 14],
			[20, 14, 23, 14],
			[28, 14, 38, 14],

			# T4, y=320: side ledges only -- the centre is the pad's flight path.
			[2, 10, 8, 10],
			[35, 10, 41, 10],

			# T5, y=192: two short high perches, kept well clear of the centre so
			# the crow's nest stays out of jumping range.
			[2, 6, 7, 6],
			[36, 6, 41, 6],
		],
		"oneway": [
			[12, 18, 16, 18], [27, 18, 31, 18],   # T2 bridges
			[11, 10, 16, 10], [27, 10, 32, 10],   # T4 stepping stones
			[19, 4, 24, 4],                       # the crow's nest
		],
		# All four on T1, mirrored about the map centre (x = 704).
		"spawns": [
			Vector2(144, 704), Vector2(1264, 704),
			Vector2(592, 704), Vector2(816, 704),
		],
		"generators": [
			{"pos": Vector2(161, 832), "pickup": SWORD},
			{"pos": Vector2(1217, 832), "pickup": SWORD},
			{"pos": Vector2(641, 576), "pickup": SWORD},
			{"pos": Vector2(737, 576), "pickup": SWORD},
			{"pos": Vector2(225, 448), "pickup": GUN},
			{"pos": Vector2(1153, 448), "pickup": GUN},
			{"pos": Vector2(129, 192), "pickup": GUN},
			{"pos": Vector2(1249, 192), "pickup": GUN},
			{"pos": Vector2(689, 128), "pickup": GUN},   # crow's nest reward
		],
		"zones": [
			# Visible death in the mouth of the floor pit, so the hazard reads
			# before a player falls in rather than after.
			{"effect": "KILL", "rect": Rect2(640, 848, 128, 40)},
			# ...and the void underneath, as the backstop. Well below the floor's
			# underside (y=896) so nobody standing on the floor clips it, and
			# wide enough to catch anything that leaves the map at all.
			{"effect": "KILL", "rect": Rect2(-256, 916, 1920, 200), "visual": false},
			# The only way onto the crow's nest.
			{"effect": "LAUNCH", "rect": Rect2(672, 424, 64, 24)},
			# Ice on the contested centre catwalk. Zones are drawn as a plain
			# rectangle, so they are kept flat against the surface they coat --
			# a tall box reads as a wall floating in mid-air.
			{"effect": "SLIPPERY", "rect": Rect2(608, 552, 192, 24)},
			# Tar on the ground, mirrored. STICKY blocks jumping, so each pool
			# leaves dry ground at both ends of the run it sits on -- walk out,
			# then jump. The validator fails the build if that is not true.
			{"effect": "STICKY", "rect": Rect2(160, 808, 160, 24)},
			{"effect": "STICKY", "rect": Rect2(1088, 808, 160, 24)},
		],
	}

# ARENA 2 -- "The Well": tighter and much more vertical. 38 x 30 = 1216 x 960 px.
#
# Two towers of staggered ledges you zig-zag up, and a central shaft of one-way
# platforms you can punch straight up through. The shaft stops at y=384; above it
# is 256 px of open air and a one-way crown that only the shaft's launch pad
# reaches. Two holes in the floor open onto the void.
func arena2_spec() -> Dictionary:
	return {
		"name": "Arena2",
		"cols": 38,
		"rows": 30,
		"env_modulate": Color(0.72, 0.80, 1.0),
		"solid": [
			[0, 0, 37, 0],      # ceiling
			[0, 1, 1, 27],      # left wall
			[36, 1, 37, 27],    # right wall
			[0, 28, 9, 29],     # floor, left section
			[14, 28, 23, 29],   # floor, middle section
			[28, 28, 37, 29],   # floor, right section

			# Left tower: five ledges, each 128px above the last and offset so
			# there is always an open column to jump up through.
			[2, 24, 8, 24],
			[5, 20, 13, 20],
			[2, 16, 10, 16],
			[5, 12, 13, 12],
			[2, 8, 7, 8],

			# Right tower, mirrored about col 18.5.
			[29, 24, 35, 24],
			[24, 20, 32, 20],
			[27, 16, 35, 16],
			[24, 12, 32, 12],
			[30, 8, 35, 8],
		],
		"oneway": [
			# The shaft ladder. Stacked 128px apart, so a standing jump carries
			# you up through one and onto the next.
			[15, 24, 22, 24],
			[16, 20, 21, 20],
			[15, 16, 22, 16],
			[16, 12, 21, 12],
			# The crown, 256px above the ladder's top: pad-only.
			[17, 4, 20, 4],
		],
		# All four on the y=768 tier, mirrored about the map centre (x = 608).
		"spawns": [
			Vector2(144, 768), Vector2(1072, 768),
			Vector2(528, 768), Vector2(688, 768),
		],
		"generators": [
			{"pos": Vector2(449, 896), "pickup": SWORD},
			{"pos": Vector2(737, 896), "pickup": SWORD},
			{"pos": Vector2(161, 512), "pickup": SWORD},
			{"pos": Vector2(1025, 512), "pickup": SWORD},
			{"pos": Vector2(129, 256), "pickup": GUN},
			{"pos": Vector2(1057, 256), "pickup": GUN},
			{"pos": Vector2(593, 128), "pickup": GUN},   # crown reward
		],
		"zones": [
			{"effect": "KILL", "rect": Rect2(320, 912, 128, 40)},    # left pit
			{"effect": "KILL", "rect": Rect2(768, 912, 128, 40)},    # right pit
			{"effect": "KILL", "rect": Rect2(-256, 980, 1728, 200), "visual": false},
			{"effect": "LAUNCH", "rect": Rect2(576, 872, 64, 24)},   # ground -> shaft
			{"effect": "LAUNCH", "rect": Rect2(576, 360, 64, 24)},   # shaft -> crown
			{"effect": "SLIPPERY", "rect": Rect2(480, 488, 256, 24)},
			{"effect": "STICKY", "rect": Rect2(480, 872, 96, 24)},
			{"effect": "STICKY", "rect": Rect2(640, 872, 96, 24)},
		],
	}

# ---------------------------------------------------------------------------
# Scene assembly
# ---------------------------------------------------------------------------

func _build_arena(spec: Dictionary, terrain: TileSet, oneway: TileSet) -> void:
	var cols: int = spec["cols"]
	var rows: int = spec["rows"]

	var solid := {}
	for rect in spec["solid"]:
		_fill(solid, rect)
	var ow := {}
	for rect in spec["oneway"]:
		_fill(ow, rect)

	var root := Node2D.new()
	root.name = spec["name"]
	root.set_script(load(MAP_SCRIPT))
	# Map1 carries position (61, -71) and scale (1.37, 1.16). Every distance in
	# this file, and every number the validator checks, is in world pixels, which
	# is only true while the root transform is the identity.
	root.position = Vector2.ZERO
	root.scale = Vector2.ONE

	var env := TileMap.new()
	env.name = "Environment"
	env.tile_set = terrain
	env.modulate = spec["env_modulate"]
	root.add_child(env)

	var owm := TileMap.new()
	owm.name = "OneWayPlatforms"
	owm.tile_set = oneway
	# Jump-through platforms have to read as different from terrain at a glance,
	# and the art is the same strip, so they are tinted instead.
	owm.modulate = Color(0.55, 0.95, 1.0)
	root.add_child(owm)

	for key in solid:
		var b: Vector2i = key
		_paint_block(env, b, _pick_solid(solid, b))
	for key in ow:
		var b: Vector2i = key
		_paint_block(owm, b, _pick_oneway(ow, b))

	var objects := Node2D.new()
	objects.name = "Objects"
	root.add_child(objects)
	var generator_scene: PackedScene = load(GENERATOR_SCENE)
	var index := 1
	for gen in spec["generators"]:
		var node: Node2D = generator_scene.instantiate()
		node.name = "TimedGenerator%d" % index
		node.position = gen["pos"]
		# set(): `node` is statically typed Node2D, and TimedGenerator.gd's
		# exports are not visible to the compiler through that type.
		node.set("pickup_scene", load(gen["pickup"]))
		objects.add_child(node)
		index += 1

	var zones := Node2D.new()
	zones.name = "Zones"
	root.add_child(zones)
	index = 1
	for zone in spec["zones"]:
		_add_zone(zones, zone, index)
		index += 1

	var starts := Node2D.new()
	starts.name = "PlayerStartPositions"
	root.add_child(starts)
	for i in range(spec["spawns"].size()):
		var marker := Marker2D.new()
		marker.name = "Player%d" % (i + 1)
		# Player.tscn's StandingCollisionShape spans y -56..0, so the node origin
		# IS the feet. Lifted 4px so a spawning player settles onto the floor
		# rather than starting one pixel inside it.
		marker.position = spec["spawns"][i] - Vector2(0, 4)
		starts.add_child(marker)

	var background: Node = load(BACKGROUND_SCENE).instantiate()
	background.name = "Background"
	root.add_child(background)

	_set_owner_recursive(root, root)

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		_failures += 1
		printerr("[build] FAILED to pack %s (error %d)" % [spec["name"], err])
		root.free()
		return

	_save(packed, "res://maps/%s.tscn" % spec["name"])
	print("[build] %s: %d x %d blocks = %d x %d px, %d solid, %d one-way, %d zone(s)" % [
		spec["name"], cols, rows, cols * BLOCK, rows * BLOCK,
		solid.size(), ow.size(), spec["zones"].size()])
	print(_ascii(spec, solid, ow))
	root.free()

func _fill(into: Dictionary, rect: Array) -> void:
	for c in range(rect[0], rect[2] + 1):
		for r in range(rect[1], rect[3] + 1):
			into[Vector2i(c, r)] = true

# Four 16px cells per 32px block, taking the four quadrants of the chosen art.
func _paint_block(tilemap: TileMap, block: Vector2i, atlas: Vector2i) -> void:
	for dx in range(2):
		for dy in range(2):
			tilemap.set_cell(0,
				Vector2i(block.x * 2 + dx, block.y * 2 + dy),
				1, atlas + Vector2i(dx, dy))

# Nine-slice by four-neighbourhood, falling back to the strip / column / single
# pieces when the block is only one thick in a direction.
func _pick_solid(solid: Dictionary, b: Vector2i) -> Vector2i:
	var l: bool = solid.has(b + Vector2i(-1, 0))
	var r: bool = solid.has(b + Vector2i(1, 0))
	var u: bool = solid.has(b + Vector2i(0, -1))
	var d: bool = solid.has(b + Vector2i(0, 1))

	if l and r and u and d: return T_C
	if l and r and d: return T_T
	if l and r and u: return T_B
	if u and d and r: return T_L
	if u and d and l: return T_R
	if r and d: return T_TL
	if l and d: return T_TR
	if r and u: return T_BL
	if l and u: return T_BR
	if l and r: return T_HMID
	if u and d: return T_VMID
	if r: return T_HLEFT
	if l: return T_HRIGHT
	if d: return T_VTOP
	if u: return T_VBOT
	return T_SINGLE

func _pick_oneway(ow: Dictionary, b: Vector2i) -> Vector2i:
	var l: bool = ow.has(b + Vector2i(-1, 0))
	var r: bool = ow.has(b + Vector2i(1, 0))
	if l and r: return T_HMID
	if r: return T_HLEFT
	if l: return T_HRIGHT
	return T_SINGLE

func _add_zone(parent: Node2D, zone: Dictionary, index: int) -> void:
	# Built node-by-node rather than instancing objects/EffectZone.tscn: that
	# scene's RectangleShape2D is a shared sub-resource, so resizing one
	# instance's shape would resize every zone in the map, and PackedScene.pack()
	# does not record property changes made inside a non-editable instance.
	var rect: Rect2 = zone["rect"]
	var area := Area2D.new()
	area.name = "%sZone%d" % [zone["effect"].capitalize(), index]
	area.set_script(load(EFFECT_ZONE_SCRIPT))
	area.collision_layer = 0
	area.collision_mask = 2  # Player
	area.position = rect.position + rect.size * 0.5
	# set() and the constant map, rather than `area.effect = EffectZone.Effect.X`:
	# the variable's static type is Area2D so the compiler rejects the property,
	# and naming the EffectZone class here would make this tool fail to compile
	# under --script (EffectZone.gd reaches for the GameState autoload, which is
	# not registered in that mode).
	area.set("effect", _effect_enum()[zone["effect"]])
	parent.add_child(area)

	var shape := CollisionShape2D.new()
	shape.name = "CollisionShape2D"
	var box := RectangleShape2D.new()
	box.size = rect.size
	shape.shape = box
	area.add_child(shape)

	# EffectZone draws nothing, and an invisible hazard is an unfair one.
	if not zone.get("visual", true):
		return
	var poly := Polygon2D.new()
	poly.name = "Visual"
	poly.polygon = PackedVector2Array([
		-rect.size * 0.5,
		Vector2(rect.size.x, -rect.size.y) * 0.5,
		rect.size * 0.5,
		Vector2(-rect.size.x, rect.size.y) * 0.5])
	poly.color = _zone_color(zone["effect"])
	area.add_child(poly)

func _effect_enum() -> Dictionary:
	return load(EFFECT_ZONE_SCRIPT).get_script_constant_map()["Effect"]

func _zone_color(effect: String) -> Color:
	match effect:
		"LAUNCH": return Color(0.55, 1.0, 0.35, 0.85)
		"SLIPPERY": return Color(0.65, 0.92, 1.0, 0.45)
		"STICKY": return Color(0.24, 0.17, 0.06, 0.72)
		_: return Color(0.85, 0.10, 0.12, 0.55)

# PackedScene.pack() only stores nodes owned by the root. Instanced sub-scenes
# keep their own internal children, so only the instance root is adopted.
func _set_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children():
		if child.owner == null and child != root:
			child.owner = root
		if child.scene_file_path == "":
			_set_owner_recursive(child, root)

# A block-resolution picture of the arena, printed on every build. Cheap to
# read, and it is how a layout change gets sanity-checked before the validator
# is even run.
func _ascii(spec: Dictionary, solid: Dictionary, ow: Dictionary) -> String:
	var cols: int = spec["cols"]
	var rows: int = spec["rows"]
	var marks := {}
	var n := 1
	for p in spec["spawns"]:
		marks[Vector2i(int(p.x) / BLOCK, int(p.y) / BLOCK - 1)] = str(n)
		n += 1
	for g in spec["generators"]:
		var b := Vector2i(int(g["pos"].x + 15) / BLOCK, int(g["pos"].y) / BLOCK - 1)
		if not marks.has(b):
			marks[b] = "*"
	for z in spec["zones"]:
		var rect: Rect2 = z["rect"]
		var ch: String = z["effect"].substr(0, 1)
		for c in range(int(rect.position.x) / BLOCK, int(rect.end.x + BLOCK - 1) / BLOCK):
			var b2 := Vector2i(c, int(rect.end.y - 1) / BLOCK)
			if c >= 0 and c < cols and not marks.has(b2):
				marks[b2] = ch

	var out := "\n"
	for r in range(rows):
		var line := "%3d " % r
		for c in range(cols):
			var b3 := Vector2i(c, r)
			if solid.has(b3):
				line += "#"
			elif ow.has(b3):
				line += "="
			elif marks.has(b3):
				line += marks[b3]
			else:
				line += "."
		out += line + "\n"
	return out
