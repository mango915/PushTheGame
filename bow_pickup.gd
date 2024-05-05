extends Area2D

const bow_scene = preload("res://Scenes/Weapons/Bow/bow.tscn")
var player_inside

# Called when the node enters the scene tree for the first time.
func _ready():
	#$AnimationPlayer.play("default_animation")
	pass # Replace with function body.

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass

func _on_body_entered(body: Node2D):
	print("body entered")
	player_inside = body
	attach_weapon()

#@rpc("any_peer","call_local")
func attach_weapon():
		player_inside.get_node("WeaponAttach").get_child(0).queue_free()
		# create new weapon
		var bow = bow_scene.instantiate()
		player_inside.attach_weapon(bow)

		queue_free()

