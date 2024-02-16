extends CharacterBody2D

var dir: Vector2 = Vector2.ZERO
var speed: float = 1200.0
var gravity: float = 1000.0

func _ready() -> void:
	velocity = dir.normalized() * speed
	rotation = velocity.angle()

		
func _physics_process(delta: float) -> void:
	rotation = velocity.angle()
	velocity.y += gravity * delta
	
	var collision = move_and_collide(velocity * delta)
	if not collision: return
	if collision.get_collider().has_method("take_damage"):
		collision.get_collider().take_damage.rpc()
	
	queue_free()
	#velocity = velocity.bounce(collision.get_normal()) * 0.6
