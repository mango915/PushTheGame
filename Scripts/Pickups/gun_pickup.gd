extends Area2D

const bow_scene = preload("res://Scenes/Weapons/Gun/gun.tscn")
var player_inside

# Called when the node enters the scene tree for the first time.
func _ready():
	$AnimationPlayer.play("default_animation")

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass

func pickup(player):

	player.get_node("WeaponAttach").get_child(0).queue_free()
	var bow = bow_scene.instantiate()
	player.attach_weapon(bow)

	queue_free()
