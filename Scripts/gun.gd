extends Node2D

@export var bullet_scene: PackedScene

# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta):
	
	if get_parent().get_parent().get_node("MultiplayerSynchronizer").get_multiplayer_authority() != multiplayer.get_unique_id():
		return
		
	if get_parent().get_parent().is_dead:
		return
		
	# look left or right horizontally depending on mouse position
	var dir = get_global_mouse_position() - global_position
	if dir.x < 0:
		scale = Vector2( - 1, 1)
	else:
		scale = Vector2(1, 1)

	if Input.is_action_just_pressed("fire") and get_parent().get_parent().can_shoot:
		fire.rpc(get_global_mouse_position())

@rpc("any_peer", "call_local")
func fire(direction):
	var bullet = bullet_scene.instantiate()
	bullet.global_position = $BulletSpawn.global_position
	# shoot bullet parallel to ground depending on mouse position
	var dir = direction - global_position
	dir = dir.normalized()
	dir.y = 0
	bullet.global_rotation = dir.angle()
	bullet.dir = dir

	bullet.speed = 5000
	get_tree().root.add_child(bullet)
