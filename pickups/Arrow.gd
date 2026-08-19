extends Area2D

# A bow's arrow. Unlike Projectile it ARCS: gravity is what makes draw force
# mean something, because a weak shot falls short instead of being a slower kill.
#
# Damage goes through components/Hitbox.gd, the same Area2D the sword swings and
# the grenade blast uses, so the "who decides this player got hurt" rule online
# lives in exactly one place.

const GRAVITY := 900.0
# Nothing lives forever: an arrow that leaves the map must not sit in the scene
# accumulating speed for the rest of the match.
const MAX_LIFETIME := 6.0

var velocity := Vector2.ZERO
var _life := 0.0
var _spent := false

@onready var hitbox = get_node_or_null("Hitbox")

func launch(from: Vector2, dir: Vector2, speed: float) -> void:
	global_position = from
	velocity = dir.normalized() * speed
	rotation = velocity.angle()

func _physics_process(delta: float) -> void:
	if _spent:
		return

	_life += delta
	if _life >= MAX_LIFETIME:
		queue_free()
		return

	velocity.y += GRAVITY * delta
	global_position += velocity * delta
	# Point where it is going, which is what sells the arc.
	rotation = velocity.angle()

# Terrain. The arrow's own mask is the Environment layer, so anything it reports
# here is a wall or a floor.
func _on_body_entered(_body: Node) -> void:
	_stick()

func _stick() -> void:
	if _spent:
		return
	_spent = true
	velocity = Vector2.ZERO
	# Stops killing the moment it stops flying: an arrow embedded in a wall is
	# scenery, and players walk past walls constantly.
	if hitbox != null:
		hitbox.disabled = true
	set_deferred("monitoring", false)
	# Left briefly so the shot reads as having landed somewhere, then cleaned up.
	await get_tree().create_timer(1.5).timeout
	queue_free()
