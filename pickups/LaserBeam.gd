extends Line2D

# The visible half of a hitscan shot: the beam exists for one frame of physics,
# so something has to stay on screen long enough to be read. A bright core over
# a wide translucent glow, both fading out together.
#
# Carries no gameplay at all. Laser.gd has already decided who was hit before
# this is ever instanced, on exactly one peer, and every peer is handed the same
# two endpoints -- so this can be spawned freely without any authority check.

@onready var glow: Line2D = get_node_or_null("Glow")

func show_beam(from: Vector2, to: Vector2, duration: float) -> void:
	# The endpoints arrive in GLOBAL coordinates (they come off a raycast, and
	# over the network from another peer), while Line2D points are local. Going
	# top-level makes the two the same thing, whatever the map node happens to
	# be scaled or offset by. Same trick Projectile.gd uses for its trail.
	set_as_top_level(true)
	transform = Transform2D.IDENTITY

	var beam := PackedVector2Array([from, to])
	points = beam
	if glow != null:
		glow.points = beam

	var fade := maxf(0.02, duration)
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, fade)
	tween.tween_callback(queue_free)
