extends Node

# Proves that every platform in maps/Arena1.tscn and maps/Arena2.tscn can
# actually be reached, using the game's own movement numbers.
#
# WHY THIS EXISTS
# ---------------
# The complaint that started this work was "on the first map I cannot jump to
# all places". A level editor will happily let you place a ledge 400px above
# anything, and nothing in the engine complains -- the map just quietly has a
# room nobody can enter. Eyeballing a layout does not catch it, because the
# reachable set depends on gravity, jump_speed, speed and acceleration together,
# and those live in a settings resource that anyone can retune.
#
# So this test does not check a hand-written list of "expected" platforms. It
# extracts every standable surface from the tiles, simulates the player's real
# equations of motion off each one, and asserts the resulting graph is connected
# in BOTH directions from all four spawn points. Retune jump_speed in
# resources/default_game_settings.tres and this test re-decides the answer.
#
# THE MOVEMENT MODEL
# ------------------
# Taken from actors/player-states/{Move,Jump,Fall}.gd and Player.gd:
#   * jump sets vector.y = -jump_speed and only works from is_on_floor()
#   * horizontal input accelerates toward +/- speed at `acceleration` px/s^2,
#     in the air exactly as on the ground (Jump/Fall both call Move.do_move)
#   * gravity is applied every frame and clamped to terminal_velocity
#   * one-way platforms block downward motion only
#   * an EffectZone with STICKY sets jump_blocked, so you cannot jump out of one
#   * an EffectZone with LAUNCH overrides vector.y with -launch_speed
#
# Deliberately NOT modelled, so the proof is conservative -- every one of these
# would only make MORE of the map reachable:
#   * the glide in Fall.gd (holding jump caps fall speed at 100 px/s, which
#     hugely extends horizontal range on the way down)
#   * being thrown, or bouncing off another player
#   * variable jump height / short-hopping
#   * a running start longer than the launch surface itself
#
# The player box is 29x56 (Player.tscn's StandingCollisionShape) with its origin
# at the feet; the sim uses a slightly wider 30px box so a passage has to be
# genuinely clear, not clear to the pixel.

const TAG := "map"

const ARENAS := ["res://maps/Arena1.tscn", "res://maps/Arena2.tscn"]

const CELL := 16.0
const PLAYER_HALF_WIDTH := 15.0
const PLAYER_HEIGHT := 56.0
# Cells of clear air a surface needs above it before a player can stand there.
const HEADROOM_CELLS := 4  # 64px >= the 56px player

const EMPTY := 0
const SOLID := 1
const ONEWAY := 2

const SIM_DT := 1.0 / 60.0     # the project's physics tick
const SIM_MAX_TIME := 3.0
# Launch points are sampled every N cells along a surface, plus both ends.
const LAUNCH_STRIDE := 2

# One-way physics probe: how far above the platform the probe body starts, and
# how much clear space the chosen platform needs. PROBE_DROP + the 56px body
# must fit inside PROBE_CLEAR_ABOVE cells of air.
const PROBE_DROP := 32.0
const PROBE_CLEAR_ABOVE := 6
const PROBE_CLEAR_BELOW := 4

var _failures := 0

# --- per-arena state, rebuilt by _load_arena() ------------------------------
var _map: Node2D
var _settings: GameSettings
var _grid := PackedByteArray()
var _gw := 0
var _gh := 0
var _gx := 0     # cell coords of grid index 0
var _gy := 0
var _surfaces: Array = []      # {row_y, x0, x1, cy, cx0, cx1, oneway, sticky, pad}
var _surface_at_cell := {}     # Vector2i(cx, cy) -> surface index
var _kill_rects: Array = []
var _sticky_rects: Array = []
var _launch_rects: Array = []
var _slippery_rects: Array = []
var _edges: Array = []         # per surface: Dictionary of dest -> edge info

# ---------------------------------------------------------------------------

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[%s] OK: %s" % [TAG, label])
	else:
		_failures += 1
		print("[%s] FAIL: %s (expected %s, got %s)" % [
			TAG, label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[%s] starting" % TAG)

	_settings = _load_settings()
	var g := _settings.get_gravity()
	print("[%s] budget: gravity %.0f, jump %.0f -> height %.0f px, airtime %.2f s, distance %.0f px" % [
		TAG, g, _settings.jump_speed, _settings.get_jump_height(),
		_settings.get_jump_airtime(), _settings.get_jump_distance()])

	# A zero or negative budget would make every "unreachable" verdict below
	# meaningless, so fail loudly rather than pass vacuously.
	_check_true("jump height is positive", _settings.get_jump_height() > 0.0)
	_check_true("jump distance is positive", _settings.get_jump_distance() > 0.0)

	for path in ARENAS:
		await _check_arena(path)

	print("[%s] %d assertion(s) failed" % [TAG, _failures])
	get_tree().quit(0)

# The shipped defaults, not GameSettings.load_saved(): a developer's saved
# user://settings.cfg must not change whether the maps pass CI.
func _load_settings() -> GameSettings:
	var res = load(GameSettings.DEFAULTS_PATH)
	if res is GameSettings:
		return res.duplicate_settings()
	return GameSettings.new()

# ---------------------------------------------------------------------------
# Per-arena driver
# ---------------------------------------------------------------------------

func _check_arena(path: String) -> void:
	var name := path.get_file().get_basename()
	print("[%s] --- %s ---" % [TAG, name])

	var packed: PackedScene = load(path)
	if packed == null:
		_failures += 1
		print("[%s] FAIL: %s does not load" % [TAG, name])
		return

	_map = packed.instantiate()
	add_child(_map)
	await get_tree().physics_frame

	_check_structure(name)
	_check_map_rect(name)
	_read_zones()
	_build_grid()
	_find_surfaces()
	_build_edges()

	_check_spawns(name)
	_check_connectivity(name)
	_check_sticky_escapes(name)
	await _check_one_way_physics(name)
	_report_demands(name)

	_map.queue_free()
	_map = null
	await get_tree().physics_frame

# What Game.gd reaches for by name when it sets a round up. A rename here is a
# crash on round start, not a wrong pixel.
func _check_structure(name: String) -> void:
	_check_true("%s: root runs maps/Map.gd" % name,
		_map.get_script() != null
			and _map.get_script().resource_path == "res://maps/Map.gd")
	# Map1's root carries position (61, -71) and scale (1.37, 1.16), which makes
	# every world coordinate in the map a different number from the one in the
	# editor. The arenas must stay in identity space or none of the maths below
	# (or in Map.get_map_rect) means what it says.
	_check("%s: root position is the origin" % name, _map.position, Vector2.ZERO)
	_check("%s: root scale is 1:1" % name, _map.scale, Vector2.ONE)
	_check_true("%s: has an Environment TileMap" % name,
		_map.get_node_or_null("Environment") is TileMap)
	_check_true("%s: has a OneWayPlatforms TileMap" % name,
		_map.get_node_or_null("OneWayPlatforms") is TileMap)
	_check_true("%s: has PlayerStartPositions" % name,
		_map.get_node_or_null("PlayerStartPositions") != null)

	var env := _map.get_node_or_null("Environment") as TileMap
	if env != null and env.tile_set != null and env.tile_set.get_physics_layers_count() > 0:
		# 255 (Map1's value) puts terrain on the Pickup layer too, so the
		# player's PickupArea reports every wall it brushes as a pickup.
		_check("%s: terrain is on the Environment layer only" % name,
			env.tile_set.get_physics_layer_collision_layer(0), 1)

	var ow := _map.get_node_or_null("OneWayPlatforms") as TileMap
	if ow != null and ow.tile_set != null and ow.tile_set.get_physics_layers_count() > 0:
		# 16 is layer 5, the one Player.tscn's mask of 17 includes and that
		# duck+jump clears to drop through.
		_check("%s: one-way tiles are on the OneWayPlatforms layer" % name,
			ow.tile_set.get_physics_layer_collision_layer(0), 16)
		var one_way_tiles := 0
		var src := ow.tile_set.get_source(ow.tile_set.get_source_id(0)) as TileSetAtlasSource
		if src != null:
			for i in range(src.get_tiles_count()):
				var data := src.get_tile_data(src.get_tile_id(i), 0)
				if data.get_collision_polygons_count(0) > 0 \
						and data.is_collision_polygon_one_way(0, 0):
					one_way_tiles += 1
		_check_true("%s: one-way tileset has one-way collision polygons" % name,
			one_way_tiles > 0)

func _check_map_rect(name: String) -> void:
	var rect: Rect2 = _map.get_map_rect()
	# Game.reload_map() feeds this straight into the Camera2D limits. A
	# degenerate or origin-anchored rect pins the camera somewhere with no level
	# in it, which is exactly what the old Map.gd used to produce.
	_check_true("%s: map rect is non-degenerate" % name,
		rect.size.x > 320.0 and rect.size.y > 180.0)
	_check_true("%s: map rect starts at the origin" % name,
		rect.position.is_equal_approx(Vector2.ZERO))
	print("[%s] %s: map rect %.0f,%.0f %.0f x %.0f" % [
		TAG, name, rect.position.x, rect.position.y, rect.size.x, rect.size.y])

# ---------------------------------------------------------------------------
# Reading the map
# ---------------------------------------------------------------------------

func _read_zones() -> void:
	_kill_rects.clear()
	_sticky_rects.clear()
	_launch_rects.clear()
	_slippery_rects.clear()
	var zones := _map.get_node_or_null("Zones")
	if zones == null:
		return
	for child in zones.get_children():
		if not (child is Area2D):
			continue
		var shape := child.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if shape == null or not (shape.shape is RectangleShape2D):
			continue
		var size: Vector2 = (shape.shape as RectangleShape2D).size
		var centre: Vector2 = child.position + shape.position
		var rect := Rect2(centre - size * 0.5, size)
		match int(child.get("effect")):
			0: _launch_rects.append(rect)
			1: _kill_rects.append(rect)
			2: _slippery_rects.append(rect)
			3: _sticky_rects.append(rect)

# Both TileMaps flattened into one byte grid. A cell is only recorded if its
# tile actually carries collision -- a decorative tile must not be walked on.
func _build_grid() -> void:
	var env := _map.get_node("Environment") as TileMap
	var ow := _map.get_node("OneWayPlatforms") as TileMap

	var solid_cells := _collidable_cells(env)
	var oneway_cells := _collidable_cells(ow)

	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for c in solid_cells + oneway_cells:
		lo.x = mini(lo.x, c.x); lo.y = mini(lo.y, c.y)
		hi.x = maxi(hi.x, c.x); hi.y = maxi(hi.y, c.y)

	_gx = lo.x
	_gy = lo.y
	_gw = hi.x - lo.x + 1
	_gh = hi.y - lo.y + 1
	_grid = PackedByteArray()
	_grid.resize(_gw * _gh)
	_grid.fill(EMPTY)
	for c in oneway_cells:
		_grid[(c.y - _gy) * _gw + (c.x - _gx)] = ONEWAY
	for c in solid_cells:
		_grid[(c.y - _gy) * _gw + (c.x - _gx)] = SOLID

func _collidable_cells(tilemap: TileMap) -> Array:
	var out := []
	if tilemap == null or tilemap.tile_set == null:
		return out
	for c in tilemap.get_used_cells(0):
		var data := tilemap.get_cell_tile_data(0, c)
		if data != null and data.get_collision_polygons_count(0) > 0:
			out.append(c)
	return out

func _at(cx: int, cy: int) -> int:
	var lx := cx - _gx
	var ly := cy - _gy
	if lx < 0 or ly < 0 or lx >= _gw or ly >= _gh:
		return EMPTY
	return _grid[ly * _gw + lx]

# A standable cell: has collision, nothing solid in the cell above, and enough
# clear air over it for a 56px player. One-way tiles overhead do not count as a
# ceiling -- you jump straight through them.
func _is_surface_cell(cx: int, cy: int) -> bool:
	# The topmost row of tiles is the map's lid, and its OUTER face has open sky
	# above it, so it passes every test below. It is not part of the arena --
	# nobody can get on top of the roof -- and counting it would report a
	# permanent unreachable island on any enclosed map.
	if cy <= _gy:
		return false
	if _at(cx, cy) == EMPTY:
		return false
	if _at(cx, cy - 1) != EMPTY:
		return false
	for i in range(2, HEADROOM_CELLS + 1):
		if _at(cx, cy - i) == SOLID:
			return false
	return true

# Runs of adjacent standable cells in the same row become one surface, because
# a player can walk from any part of such a run to any other.
func _find_surfaces() -> void:
	_surfaces.clear()
	_surface_at_cell.clear()
	for ly in range(_gh):
		var cy := _gy + ly
		var run_start := -1
		for lx in range(_gw + 1):
			var cx := _gx + lx
			var standable := lx < _gw and _is_surface_cell(cx, cy)
			if standable and run_start < 0:
				run_start = cx
			elif not standable and run_start >= 0:
				_add_surface(cy, run_start, cx - 1)
				run_start = -1

func _add_surface(cy: int, cx0: int, cx1: int) -> void:
	var index := _surfaces.size()
	var y := float(cy) * CELL
	var sticky := false
	var pad := false
	var oneway := false
	for cx in range(cx0, cx1 + 1):
		_surface_at_cell[Vector2i(cx, cy)] = index
		var probe := Vector2(float(cx) * CELL + CELL * 0.5, y - 1.0)
		if _in_any(_sticky_rects, probe):
			sticky = true
		if _in_any(_launch_rects, probe):
			pad = true
		if _at(cx, cy) == ONEWAY:
			oneway = true
	_surfaces.append({
		"y": y,
		"x0": float(cx0) * CELL,
		"x1": float(cx1 + 1) * CELL,
		"cy": cy, "cx0": cx0, "cx1": cx1,
		"oneway": oneway, "sticky": sticky, "pad": pad,
	})

func _in_any(rects: Array, p: Vector2) -> bool:
	for r in rects:
		if (r as Rect2).has_point(p):
			return true
	return false

func _cell_sticky(cx: int, cy: int) -> bool:
	return _in_any(_sticky_rects,
		Vector2(float(cx) * CELL + CELL * 0.5, float(cy) * CELL - 1.0))

func _cell_pad(cx: int, cy: int) -> bool:
	return _in_any(_launch_rects,
		Vector2(float(cx) * CELL + CELL * 0.5, float(cy) * CELL - 1.0))

# ---------------------------------------------------------------------------
# The movement graph
# ---------------------------------------------------------------------------

func _build_edges() -> void:
	_edges.clear()
	for i in range(_surfaces.size()):
		_edges.append({})

	for i in range(_surfaces.size()):
		var s: Dictionary = _surfaces[i]
		var launch_cells := _launch_cells(s)
		for cx in launch_cells:
			var x := float(cx) * CELL + CELL * 0.5
			var y: float = s["y"]
			var sticky: bool = _cell_sticky(cx, s["cy"])
			for dir in [-1, 0, 1]:
				# Walking off an edge, then falling.
				if (cx == s["cx0"] and dir == -1) or (cx == s["cx1"] and dir == 1):
					_record(i, x, y, dir, 0.0, "fall")
				# A normal jump. STICKY sets Player.jump_blocked, so a player
				# standing in tar has this option taken away.
				if not sticky:
					_record(i, x, y, dir, -_settings.jump_speed, "jump")
				# A launch pad writes vector.y directly and does not consult
				# jump_blocked, so it works even out of tar.
				if _cell_pad(cx, s["cy"]):
					_record(i, x, y, dir, -_launch_speed(), "pad")
				# Duck + jump drops through a one-way platform (Duck.gd clears
				# layer 5 from the player's mask).
				if s["oneway"]:
					_record(i, x, y + 2.0, dir, 0.0, "drop")

func _launch_cells(s: Dictionary) -> Array:
	var cells := []
	var cx: int = s["cx0"]
	while cx <= int(s["cx1"]):
		cells.append(cx)
		cx += LAUNCH_STRIDE
	if not cells.has(int(s["cx1"])):
		cells.append(int(s["cx1"]))
	return cells

# EffectZone's default. Read off an actual pad so retuning the scene retunes the
# proof; falls back to the script's default if a map has no pads.
func _launch_speed() -> float:
	var zones := _map.get_node_or_null("Zones")
	if zones != null:
		for child in zones.get_children():
			if child is Area2D and int(child.get("effect")) == 0:
				return float(child.get("launch_speed"))
	return 1150.0

func _record(from: int, x: float, y: float, dir: int, vy0: float, kind: String) -> void:
	var to := _simulate(x, y, dir, vy0, from)
	if to < 0 or to == from:
		return
	var existing = _edges[from].get(to)
	# Prefer to remember the cheapest way of making a connection: a route that
	# exists without a pad is what "the layout demands" really means.
	if existing != null and existing["kind"] != "pad" and kind == "pad":
		return
	_edges[from][to] = {"kind": kind, "dir": dir}

# Integrates one attempt and returns the surface landed on, or -1.
func _simulate(x0: float, y0: float, dir: int, vy0: float, from_surface: int) -> int:
	var speed := _settings.speed
	var accel := _settings.acceleration
	var gravity := _settings.get_gravity()
	var terminal := _settings.terminal_velocity

	var x := x0
	var y := y0
	var vy := vy0
	# A launch point in the middle of a platform has room to build up speed
	# before the edge; v^2 = 2*a*d is the honest amount, and it is capped by the
	# walking speed. Ignoring it entirely would understate long jumps.
	var runup: float = abs(x - (_surfaces[from_surface]["x0"] if dir < 0 else _surfaces[from_surface]["x1"]))
	var vx := 0.0
	if dir != 0:
		vx = float(dir) * minf(speed, sqrt(2.0 * accel * maxf(runup, 0.0)))

	var t := 0.0
	var floor_limit := float(_gy + _gh + 40) * CELL
	while t < SIM_MAX_TIME:
		t += SIM_DT
		if dir > 0:
			vx = minf(speed, vx + accel * SIM_DT)
		elif dir < 0:
			vx = maxf(-speed, vx - accel * SIM_DT)
		else:
			vx = 0.0
		vy = minf(terminal, vy + gravity * SIM_DT)

		var nx := x + vx * SIM_DT
		if _box_hits_solid(nx, y):
			vx = 0.0
		else:
			x = nx

		var ny := y + vy * SIM_DT
		if vy < 0.0:
			# Heads only stop on solid: one-way platforms are transparent going up.
			if _box_hits_solid(x, ny):
				vy = 0.0
			else:
				y = ny
		else:
			var landing := _landing(x, y, ny)
			if landing < INF:
				if _box_hits_solid(x, landing):
					return -1  # would end up inside geometry; not a real route
				return _surface_under(x, landing)
			y = ny

		# Dying on the way does not count as getting there.
		if _box_hits_kill(x, y):
			return -1
		if y > floor_limit:
			return -1
	return -1

# The player's box at feet position (x, y) overlapping any SOLID cell.
func _box_hits_solid(x: float, y: float) -> bool:
	var cx0 := int(floor((x - PLAYER_HALF_WIDTH) / CELL))
	var cx1 := int(floor((x + PLAYER_HALF_WIDTH - 0.001) / CELL))
	var cy0 := int(floor((y - PLAYER_HEIGHT + 0.001) / CELL))
	var cy1 := int(floor((y - 0.001) / CELL))
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			if _at(cx, cy) == SOLID:
				return true
	return false

func _box_hits_kill(x: float, y: float) -> bool:
	if _kill_rects.is_empty():
		return false
	var box := Rect2(x - PLAYER_HALF_WIDTH, y - PLAYER_HEIGHT,
		PLAYER_HALF_WIDTH * 2.0, PLAYER_HEIGHT)
	for r in _kill_rects:
		if (r as Rect2).intersects(box):
			return true
	return false

# The highest surface top strictly between the old and new feet position, over
# any cell column the player's box covers. INF when nothing was crossed.
func _landing(x: float, y_from: float, y_to: float) -> float:
	var cx0 := int(floor((x - PLAYER_HALF_WIDTH) / CELL))
	var cx1 := int(floor((x + PLAYER_HALF_WIDTH - 0.001) / CELL))
	var cy0 := int(floor(y_from / CELL))
	var cy1 := int(floor(y_to / CELL))
	var best := INF
	for cy in range(cy0, cy1 + 1):
		var top := float(cy) * CELL
		if top <= y_from or top > y_to:
			continue
		for cx in range(cx0, cx1 + 1):
			if _at(cx, cy) != EMPTY and _at(cx, cy - 1) == EMPTY:
				best = minf(best, top)
				break
	return best

func _surface_under(x: float, y: float) -> int:
	var cy := int(round(y / CELL))
	var cx0 := int(floor((x - PLAYER_HALF_WIDTH) / CELL))
	var cx1 := int(floor((x + PLAYER_HALF_WIDTH - 0.001) / CELL))
	for cx in range(cx0, cx1 + 1):
		var s = _surface_at_cell.get(Vector2i(cx, cy))
		if s != null:
			return int(s)
	return -1

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

func _check_spawns(name: String) -> void:
	var starts := _map.get_node_or_null("PlayerStartPositions")
	if starts == null:
		return
	var rect: Rect2 = _map.get_map_rect()
	for i in range(1, 5):
		var marker := starts.get_node_or_null("Player%d" % i) as Marker2D
		if marker == null:
			_failures += 1
			print("[%s] FAIL: %s has no PlayerStartPositions/Player%d" % [TAG, name, i])
			continue
		var p: Vector2 = marker.position

		_check_true("%s: Player%d spawn is inside the map rect" % [name, i],
			rect.has_point(p))
		# Player.tscn's collision box hangs above the origin, so a marker with
		# its own feet clear can still have its body buried in a ceiling.
		_check_true("%s: Player%d does not spawn inside geometry" % [name, i],
			not _box_hits_solid(p.x, p.y))
		_check_true("%s: Player%d does not spawn in a kill zone" % [name, i],
			not _box_hits_kill(p.x, p.y))

		# Drop them and see what catches them. Anything other than a surface --
		# a pit, the void, the bottom of the world -- is a spawn that kills.
		var landed := _simulate(p.x, p.y, 0, 0.0, 0)
		_check_true("%s: Player%d spawns over solid ground" % [name, i], landed >= 0)
		if landed >= 0:
			var drop: float = _surfaces[landed]["y"] - p.y
			_check_true("%s: Player%d's ground is right under them (%.0f px)" % [
				name, i, drop], drop >= 0.0 and drop <= 64.0)

func _spawn_surfaces() -> Array:
	var out := []
	var starts := _map.get_node_or_null("PlayerStartPositions")
	if starts == null:
		return out
	for i in range(1, 5):
		var marker := starts.get_node_or_null("Player%d" % i) as Marker2D
		if marker == null:
			continue
		var s := _simulate(marker.position.x, marker.position.y, 0, 0.0, 0)
		if s >= 0 and not out.has(s):
			out.append(s)
	return out

func _check_connectivity(name: String) -> void:
	var total := _surfaces.size()
	var edge_count := 0
	for e in _edges:
		edge_count += e.size()
	print("[%s] %s: %d standable surface(s), %d connection(s)" % [
		TAG, name, total, edge_count])
	_check_true("%s: the map has standable surfaces" % name, total > 0)

	var spawns := _spawn_surfaces()
	_check("%s: all four spawns land on a surface" % name, spawns.size() > 0, true)

	# Forward: everything can be got TO from where players start.
	var forward := _reach(spawns, false)
	var unreachable := _missing(forward)
	if unreachable.is_empty():
		print("[%s] OK: %s: every surface is reachable from the spawns" % [TAG, name])
	else:
		_failures += 1
		print("[%s] FAIL: %s: %d surface(s) unreachable from the spawns" % [
			TAG, name, unreachable.size()])
		_print_surfaces(unreachable)

	# Backward: and everything can be got OUT of again. A ledge you can drop
	# into but never leave is a softlock, and the forward test alone misses it.
	var backward := _reach(spawns, true)
	var stranded := _missing(backward)
	if stranded.is_empty():
		print("[%s] OK: %s: every surface can return to the spawns" % [TAG, name])
	else:
		_failures += 1
		print("[%s] FAIL: %s: %d surface(s) cannot get back to the spawns" % [
			TAG, name, stranded.size()])
		_print_surfaces(stranded)

func _reach(seeds: Array, reverse: bool) -> Dictionary:
	var adjacency := _edges
	if reverse:
		adjacency = []
		for i in range(_surfaces.size()):
			adjacency.append({})
		for i in range(_edges.size()):
			for j in _edges[i]:
				adjacency[j][i] = _edges[i][j]

	var seen := {}
	var queue := seeds.duplicate()
	for s in queue:
		seen[s] = true
	while not queue.is_empty():
		var current: int = queue.pop_back()
		for next in adjacency[current]:
			if not seen.has(next):
				seen[next] = true
				queue.append(next)
	return seen

func _missing(seen: Dictionary) -> Array:
	var out := []
	for i in range(_surfaces.size()):
		if not seen.has(i):
			out.append(i)
	return out

func _print_surfaces(indices: Array) -> void:
	for i in indices:
		var s: Dictionary = _surfaces[i]
		print("[%s]     surface %d at x %.0f..%.0f, y %.0f%s" % [
			TAG, i, s["x0"], s["x1"], s["y"],
			" (one-way)" if s["oneway"] else ""])

# STICKY blocks jumping outright. A tar pool with walls on both sides and no pad
# is a hole a player falls into and can never leave -- the exact kind of thing
# the owner would find and hate -- and connectivity alone will not catch it,
# because the surface still has "fall" edges out of a map with no floor below.
func _check_sticky_escapes(name: String) -> void:
	var trapped := []
	for i in range(_surfaces.size()):
		var s: Dictionary = _surfaces[i]
		if not s["sticky"]:
			continue
		if s["pad"]:
			continue  # a pad launches you regardless of jump_blocked
		# Somewhere on this run you can stand and still jump?
		var has_dry_ground := false
		for cx in range(int(s["cx0"]), int(s["cx1"]) + 1):
			if not _cell_sticky(cx, int(s["cy"])):
				has_dry_ground = true
				break
		if has_dry_ground:
			continue
		# Otherwise the only way off is to walk over an edge and fall.
		var can_walk_off := false
		for e in _edges[i]:
			if _edges[i][e]["kind"] == "fall":
				can_walk_off = true
				break
		if not can_walk_off:
			trapped.append(i)

	if trapped.is_empty():
		print("[%s] OK: %s: no sticky zone traps a player" % [TAG, name])
	else:
		_failures += 1
		print("[%s] FAIL: %s: %d sticky surface(s) with no way out" % [
			TAG, name, trapped.size()])
		_print_surfaces(trapped)

# ---------------------------------------------------------------------------
# One-way platforms, against the real physics server
# ---------------------------------------------------------------------------

# The reachability sim assumes one-way platforms behave a particular way. That
# assumption is worth exactly nothing unless the tiles really are set up for it,
# and "collides with nothing" is precisely the state Map1's OneWayPlatforms
# TileMap has been in since the Godot 4 port. So: drop a body with the player's
# real collision_mask of 17 onto one and see what happens, then clear layer 5
# from the mask (what Duck.gd does) and check it falls through.
func _check_one_way_physics(name: String) -> void:
	var target := _pick_one_way_probe_site()
	if target == Vector2.ZERO:
		print("[%s] FAIL: %s: found no testable one-way platform" % [TAG, name])
		_failures += 1
		return

	var body := CharacterBody2D.new()
	body.collision_layer = 2       # Player
	body.collision_mask = 17       # Environment | OneWayPlatforms, as Player.tscn
	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = Vector2(29, 56)
	shape.shape = box
	shape.position = Vector2(0, -28)
	body.add_child(shape)
	body.position = Vector2(target.x, target.y - PROBE_DROP)
	_map.add_child(body)
	await get_tree().physics_frame

	var landed_y := await _drop(body, 90)
	_check_true("%s: a mask-17 body lands on the one-way platform" % name,
		landed_y != INF and absf(landed_y - target.y) < 4.0)

	# Duck.gd clears layer 5 so the player drops through.
	body.position = Vector2(target.x, target.y - PROBE_DROP)
	body.set_collision_mask_value(5, false)
	var fell_y := await _drop(body, 90)
	_check_true("%s: clearing layer 5 drops the body through" % name,
		fell_y == INF or fell_y > target.y + CELL * 2.0)

	body.queue_free()

func _drop(body: CharacterBody2D, frames: int) -> float:
	var gravity := _settings.get_gravity()
	body.velocity = Vector2.ZERO
	for i in range(frames):
		body.velocity.y = minf(_settings.terminal_velocity,
			body.velocity.y + gravity * SIM_DT)
		body.move_and_slide()
		if body.is_on_floor():
			return body.position.y
		await get_tree().physics_frame
	return INF

# A one-way surface with clear air above it to fall from and clear air below it
# to fall into, so both halves of the test have somewhere to go.
func _pick_one_way_probe_site() -> Vector2:
	for i in range(_surfaces.size()):
		var s: Dictionary = _surfaces[i]
		if not s["oneway"]:
			continue
		var cx: int = (int(s["cx0"]) + int(s["cx1"])) / 2
		var cy: int = s["cy"]
		# Enough room above for the probe's 56px body plus its drop (otherwise
		# it starts with its head through the ceiling and never falls), and
		# enough below for "it went through" to be distinguishable.
		var clear_above := true
		for k in range(1, PROBE_CLEAR_ABOVE + 1):
			if _at(cx, cy - k) != EMPTY:
				clear_above = false
		var clear_below := true
		for k in range(1, PROBE_CLEAR_BELOW + 1):
			if _at(cx, cy + k) != EMPTY:
				clear_below = false
		if clear_above and clear_below:
			return Vector2(float(cx) * CELL + CELL * 0.5, float(cy) * CELL)
	return Vector2.ZERO

# ---------------------------------------------------------------------------
# What the layout actually asks of a player
# ---------------------------------------------------------------------------

# For every surface, the EASIEST way in. The largest of those is the hardest
# jump the map forces on anyone -- which is the number to compare against the
# budget, not the largest jump that happens to be possible somewhere.
func _report_demands(name: String) -> void:
	var worst_rise := 0.0
	var worst_run := 0.0
	var worst_rise_at := -1
	var worst_run_at := -1
	var pad_only := []
	var spawns := _spawn_surfaces()

	for j in range(_surfaces.size()):
		if spawns.has(j):
			continue
		var best_rise := INF
		var best_run := INF
		var has_unpadded := false
		for i in range(_edges.size()):
			if not _edges[i].has(j):
				continue
			if _edges[i][j]["kind"] == "pad":
				continue
			has_unpadded = true
			var a: Dictionary = _surfaces[i]
			var b: Dictionary = _surfaces[j]
			best_rise = minf(best_rise, maxf(0.0, a["y"] - b["y"]))
			var gap := 0.0
			if b["x0"] > a["x1"]:
				gap = b["x0"] - a["x1"]
			elif a["x0"] > b["x1"]:
				gap = a["x0"] - b["x1"]
			best_run = minf(best_run, gap)
		if not has_unpadded:
			pad_only.append(j)
			continue
		if best_rise > worst_rise:
			worst_rise = best_rise
			worst_rise_at = j
		if best_run > worst_run:
			worst_run = best_run
			worst_run_at = j

	var height := _settings.get_jump_height()
	var distance := _settings.get_jump_distance()
	print("[%s] %s: hardest forced climb %.0f px of %.0f budget (%.0f%%)%s" % [
		TAG, name, worst_rise, height,
		100.0 * worst_rise / height,
		"" if worst_rise_at < 0 else " -- surface %d at y %.0f" % [
			worst_rise_at, _surfaces[worst_rise_at]["y"]]])
	print("[%s] %s: widest forced gap %.0f px of %.0f budget (%.0f%%)%s" % [
		TAG, name, worst_run, distance,
		100.0 * worst_run / distance,
		"" if worst_run_at < 0 else " -- surface %d at y %.0f" % [
			worst_run_at, _surfaces[worst_run_at]["y"]]])

	# These are the surfaces whose only way in is a launch pad. They are allowed,
	# but they must be deliberate, so name them.
	if pad_only.is_empty():
		print("[%s] %s: no surface depends on a launch pad" % [TAG, name])
	else:
		print("[%s] %s: %d surface(s) reachable ONLY via a launch pad:" % [
			TAG, name, pad_only.size()])
		_print_surfaces(pad_only)

	# The whole point of the exercise: nothing may need more than the player has.
	_check_true("%s: the hardest forced climb is within the jump height" % name,
		worst_rise <= height)
	_check_true("%s: the widest forced gap is within the jump distance" % name,
		worst_run <= distance)
