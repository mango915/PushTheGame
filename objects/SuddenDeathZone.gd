class_name SuddenDeathZone
extends Node2D

# The sudden-death hazard: a lethal tide that rises from the bottom of the map
# until the whole arena is underwater and somebody has drowned.
#
# WHY A RISING TIDE rather than, say, hazards raining from the top:
#
#   - It ALWAYS resolves. The safe area is the part of the map rect above the
#     tide line, and that shrinks monotonically to nothing. Two players camping
#     opposite corners are first forced off their corners and then onto the same
#     shrinking island, whatever they do. Falling hazards only resolve
#     probabilistically -- a lucky camper can dodge forever.
#   - It is DETERMINISTIC, which is what makes it cheap to replicate. The tide
#     line is a pure function of one number (seconds since sudden death began),
#     so every peer draws the identical hazard in the identical place from the
#     single "sudden death has begun" message the host sends. Raining hazards
#     would need spawn positions, a shared RNG seed and per-object sync.
#   - It REUSES a tested primitive. The lethal part is an ordinary
#     EffectZone.KILL -- the same node the maps already use for their pits, with
#     the same authority gating -- so a sudden-death death travels through
#     Player.die() exactly like falling into a pit does, and Game/Main's
#     scoring and game_over_signal flow needs to know nothing about it.
#   - It is READABLE. A red tide with a bright surface line climbing the screen
#     tells the player what is about to kill them, and roughly when.

const EffectZoneScene := preload("res://objects/EffectZone.tscn")

# How far below the map rect the tide's body extends. Purely so the collision
# shape has real thickness at progress 0 instead of being a degenerate sliver.
const BODY_DEPTH := 128.0

# Drawn on top of the tilemaps (which sit at the default z_index of 0) but the
# players, pickups and explosions still need to read clearly through it, hence
# the low alpha below.
const DRAW_Z_INDEX := 5

const COLOR_START := Color(0.85, 0.16, 0.22, 0.26)
const COLOR_FULL := Color(0.72, 0.06, 0.12, 0.48)
const COLOR_SURFACE := Color(1.0, 0.55, 0.35, 0.9)

# The area the tide has to cover, in GLOBAL pixels (Map.get_map_rect()).
var map_rect: Rect2 = Rect2()

# 0 = the tide is at the very bottom of the map rect, 1 = it covers all of it.
var progress: float = 0.0

var _zone: EffectZone
var _shape: RectangleShape2D
var _body: Polygon2D
var _surface: Line2D

func _init() -> void:
	# The rect handed to setup() is in global pixels, and Game (our parent) is
	# offset in Main.tscn. top_level makes our local space the global one, so
	# nothing here has to compensate for where the parent happens to sit.
	top_level = true

func setup(rect: Rect2) -> void:
	map_rect = rect

	_body = Polygon2D.new()
	_body.name = "Body"
	_body.z_index = DRAW_Z_INDEX
	add_child(_body)

	_surface = Line2D.new()
	_surface.name = "Surface"
	_surface.width = 4.0
	_surface.default_color = COLOR_SURFACE
	_surface.z_index = DRAW_Z_INDEX + 1
	add_child(_surface)

	_zone = EffectZoneScene.instantiate()
	_zone.name = "KillZone"
	_zone.effect = EffectZone.Effect.KILL
	add_child(_zone)

	# EffectZone.tscn's CollisionShape2D carries a sub-resource shape, and Godot
	# SHARES sub-resources between instances of a scene -- resizing that one
	# would resize every pit in the loaded map too. Own shape, always.
	_shape = RectangleShape2D.new()
	var collision: CollisionShape2D = _zone.get_node("CollisionShape2D")
	collision.shape = _shape

	set_progress(0.0)

# Called every frame by Game with a value computed from the shared sudden-death
# clock, so this node holds no timer of its own and cannot drift from its peers.
func set_progress(value: float) -> void:
	progress = clampf(value, 0.0, 1.0)
	if _zone == null or map_rect.size.y <= 0.0:
		return

	# The tide line sweeps from the bottom edge of the map rect to the top.
	var top_y: float = map_rect.end.y - progress * map_rect.size.y
	var bottom_y: float = map_rect.end.y + BODY_DEPTH
	var height: float = maxf(1.0, bottom_y - top_y)
	var centre_x: float = map_rect.position.x + map_rect.size.x * 0.5

	_shape.size = Vector2(map_rect.size.x, height)
	_zone.position = Vector2(centre_x, top_y + height * 0.5)

	# The visible body stops at the bottom of the map: the extra depth exists
	# only to give the collision shape substance, and drawing it would put a
	# red band under the level from the moment sudden death starts.
	var left: float = map_rect.position.x
	var right: float = map_rect.end.x
	var visible_bottom: float = map_rect.end.y
	_body.polygon = PackedVector2Array([
		Vector2(left, top_y),
		Vector2(right, top_y),
		Vector2(right, visible_bottom),
		Vector2(left, visible_bottom),
	])
	_body.color = COLOR_START.lerp(COLOR_FULL, progress)
	_surface.points = PackedVector2Array([
		Vector2(left, top_y),
		Vector2(right, top_y),
	])

# Stop being lethal RIGHT NOW, without touching the tree.
#
# Called the instant the round is decided, which is reached from inside a
# physics callback (a body_entered -> die() -> game_over chain). Freeing this
# node or toggling the area's monitoring there is exactly what Godot refuses to
# do while it is flushing physics queries, so the zone is flagged inert instead
# and the actual deletion is left to queue_free().
func deactivate() -> void:
	if _zone != null and is_instance_valid(_zone):
		_zone.enabled = false
	visible = false

# The y of the tide line in global pixels. Only used by the tests, but it is the
# one number that describes the whole hazard, so it is worth naming.
func get_water_line() -> float:
	return map_rect.end.y - progress * map_rect.size.y
