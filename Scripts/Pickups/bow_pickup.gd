extends Area2D

const bow_scene = preload("res://Scenes/Weapons/Bow/bow.tscn")
var player_inside

var is_dropped_weapon = false

# Called when the node enters the scene tree for the first time.
func _ready():
	if not is_dropped_weapon:
		$AnimationPlayer.play("default_animation")
	else:
		$AnimationPlayer.play("drop")
	
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	if not $RayCast2D.is_colliding():
		position.y += delta*800

func pickup(player):

	player.get_node("WeaponAttach").get_child(0).queue_free()
	var bow = bow_scene.instantiate()
	player.attach_weapon(bow)
	if not is_dropped_weapon:
		$Timer.start()
		self.visible = false
		$CollisionShape2D.disabled = true
	else:
		self.queue_free()



func _on_timer_timeout():
	self.show()
	self.visible = true
	$CollisionShape2D.disabled = false
	$AnimationPlayer.play("default_animation")

