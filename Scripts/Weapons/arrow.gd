extends Area2D

var dir: Vector2 = Vector2.ZERO
var speed: float = 1200.0
var gravity_here: float = 1000.0

var velocity

func _ready() -> void:
	velocity = dir.normalized() * speed
	rotation = velocity.angle()
		
func _physics_process(delta: float) -> void:
	rotation = velocity.angle()
	velocity.y += gravity * delta
	
	position += velocity * delta
	
	#var collision = move_and_collide(velocity * delta)
	#if not collision: return
	#if collision.get_collider().has_method("take_damage"):
	#	collision.get_collider().take_damage.rpc_id(1)
	#queue_free()
	#velocity = velocity.bounce(collision.get_normal()) * 0.6

func _on_body_entered(body):
	queue_free()
	if body.has_method("take_damage") and multiplayer.is_server():
		body.take_damage(50)
