extends Node2D

const TILE_SIZE = Vector2(70, 70)

func map_start() -> void:
	get_tree().call_group("map_object", "map_object_start")

func map_stop() -> void:
	get_tree().call_group("map_object", "map_object_stop")

func get_map_rect() -> Rect2:
	var rect: Rect2
	var found_tilemap := false
	for child in get_children():
		if child is TileMap:
			# A typed Rect2 is never null, so track the first tilemap explicitly.
			# Otherwise the default zero-size rect at (0, 0) gets merged in and
			# every map's bounds wrongly stretch to include the origin.
			if not found_tilemap:
				rect = child.get_used_rect()
				found_tilemap = true
			else:
				rect = rect.merge(child.get_used_rect())
	return Rect2(rect.position * TILE_SIZE, rect.size * TILE_SIZE)
