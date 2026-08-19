extends Node2D

# Godot's fallback when a TileSet does not declare a tile_size of its own.
# Map1's inline TileSet omits it, so its cells really are 16x16.
const DEFAULT_TILE_SIZE := Vector2i(16, 16)

func map_start() -> void:
	get_tree().call_group("map_object", "map_object_start")

func map_stop() -> void:
	get_tree().call_group("map_object", "map_object_stop")

# The tile size of one TileMap, in that TileMap's own local pixels.
#
# This used to be a single `const TILE_SIZE = Vector2(70, 70)` shared by every
# map -- a leftover from the art the game shipped with before the tileset swap.
# Nothing uses 70x70 any more: assets/tilesets/tileset.tres (Map2) is 30x30 and
# Map1's inline TileSet declares no tile_size at all, so it is Godot's 16x16
# default. Reading it off each TileMap's own TileSet keeps this correct when the
# art changes again.
func _get_tile_size(tilemap: TileMap) -> Vector2:
	if tilemap.tile_set != null:
		var size := tilemap.tile_set.tile_size
		if size.x > 0 and size.y > 0:
			return Vector2(size)
	return Vector2(DEFAULT_TILE_SIZE)

# The bounding box of every TileMap in this map, in GLOBAL pixels.
#
# Game.reload_map() feeds this straight into camera.limit_left/top/right/bottom
# and Camera2D limits are global, so global is the space this has to be in.
#
# get_used_rect() is measured in CELLS, in the TileMap's own coordinates. Two
# conversions are therefore required and the old code did neither correctly:
# cells -> local pixels (using that TileMap's real tile size), and local ->
# global (through the node transforms -- both maps scale their root Node2D, and
# Map1 also offsets it). The result was camera limits several times too large
# and offset from the level, so the "keep the camera inside the level" feature
# never actually engaged.
func get_map_rect() -> Rect2:
	var rect: Rect2
	var found_tilemap := false

	for child in get_children():
		if not (child is TileMap):
			continue

		# A TileMap with no TileSet draws nothing and collides with nothing, so
		# it must not drag the camera bounds around either. Map1's
		# OneWayPlatforms is exactly this: it still holds tile data, but its
		# tile_set was lost in the Godot 4 port (see the report / Map1.tscn).
		if child.tile_set == null:
			continue

		var used_cells: Rect2i = child.get_used_rect()
		# An empty TileMap reports a zero-size rect at the origin. Merging that
		# in would wrongly stretch the bounds out to (0, 0).
		if used_cells.size.x <= 0 or used_cells.size.y <= 0:
			continue

		var tile_size := _get_tile_size(child)
		var local_rect := Rect2(
			Vector2(used_cells.position) * tile_size,
			Vector2(used_cells.size) * tile_size)
		# get_global_transform() rather than composing by hand, because a TileMap
		# with collision_animatable set is made top_level by Godot and therefore
		# deliberately ignores this Map's own position/scale.
		# Transform2D * Rect2 gives the axis-aligned box containing the
		# transformed rect, which is what camera limits want.
		var map_rect: Rect2 = child.get_global_transform() * local_rect

		# A typed Rect2 is never null, so track the first tilemap explicitly.
		# Otherwise the default zero-size rect at (0, 0) gets merged in and
		# every map's bounds wrongly stretch to include the origin.
		if not found_tilemap:
			rect = map_rect
			found_tilemap = true
		else:
			rect = rect.merge(map_rect)

	return rect
