extends Area2D

# Called when the node enters the scene tree for the first time.
func _ready():
	$AnimationPlayer.play("default_animation")
	pass # Replace with function body.

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass

func _on_body_entered(body: Node2D):
	queue_free()
	if body.has_method("heal_damage") and multiplayer.is_server():
		body.heal_damage()
