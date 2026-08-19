extends SceneTree

# Dev utility: dump what Map1's inline TileSet actually contains.
#
# Run with:
#   godot --headless --path . --script res://tools/inspect_tileset.gd
#
# Map1's TileSet is a sub-resource of the scene, so it can only be reached by
# instancing the scene. Its atlas cells are 16x16 over a 32x32 piece of art,
# which is why solid blocks come in 2x2 clusters of atlas coords.

func _initialize() -> void:
	var packed: PackedScene = load("res://maps/Map1.tscn")
	var map: Node2D = packed.instantiate()
	var env: TileMap = map.get_node("Environment")
	var ts: TileSet = env.tile_set

	print("tile_size = %s" % str(ts.tile_size))
	print("physics layers = %d" % ts.get_physics_layers_count())
	for i in range(ts.get_physics_layers_count()):
		print("  layer %d: collision_layer=%d mask=%d" % [
			i, ts.get_physics_layer_collision_layer(i),
			ts.get_physics_layer_collision_mask(i)])
	print("sources = %d" % ts.get_source_count())

	for si in range(ts.get_source_count()):
		var sid := ts.get_source_id(si)
		var src := ts.get_source(sid)
		print("source id %d : %s" % [sid, src.get_class()])
		if not (src is TileSetAtlasSource):
			continue
		var atlas: TileSetAtlasSource = src
		print("  texture_region_size = %s" % str(atlas.texture_region_size))
		print("  tiles = %d" % atlas.get_tiles_count())
		var solid: Array[String] = []
		var empty: Array[String] = []
		for ti in range(atlas.get_tiles_count()):
			var coords: Vector2i = atlas.get_tile_id(ti)
			var data: TileData = atlas.get_tile_data(coords, 0)
			var n := data.get_collision_polygons_count(0)
			if n > 0:
				solid.append("%d,%d" % [coords.x, coords.y])
			else:
				empty.append("%d,%d" % [coords.x, coords.y])
		print("  SOLID (%d): %s" % [solid.size(), " ".join(solid)])
		print("  EMPTY (%d): %s" % [empty.size(), " ".join(empty)])

	map.free()
	quit(0)
