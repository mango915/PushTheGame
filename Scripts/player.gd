extends CharacterBody2D


const SPEED = 400.0
const JUMP_VELOCITY = -1000.0

# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = 2000 #ProjectSettings.get_setting("physics/2d/default_gravity")

@export var bullet : PackedScene

func _ready():
	$MultiplayerSynchronizer.set_multiplayer_authority(str(name).to_int())
	for i in GameManager.players:
		if i == $MultiplayerSynchronizer.get_multiplayer_authority():
			$Label.text = GameManager.players[i].name
	$AnimatedSprite2D.play("default")

func _physics_process(delta):
	if $MultiplayerSynchronizer.get_multiplayer_authority() != multiplayer.get_unique_id():
		$Camera2D.enabled = false
		return
		$Camera2D.enabled = true
	# Add the gravity.
	if not is_on_floor():
		velocity.y += gravity * delta

	$GunRotation.look_at(get_viewport().get_mouse_position())
	
	var mouse_position = get_global_mouse_position()

	if mouse_position.x > position.x:
		$GunRotation/Sprite2D.flip_v = false
	elif mouse_position.x < position.x:
		$GunRotation/Sprite2D.flip_v = true
		
	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	if Input.is_action_just_pressed("fire"):
		fire.rpc()

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var direction = Input.get_axis("ui_left", "ui_right")
	if direction:
		velocity.x = direction * SPEED
		if direction < 0:
			$AnimatedSprite2D.play("run")
			$AnimatedSprite2D.flip_h = false
		else:		
			$AnimatedSprite2D.play("run")
			$AnimatedSprite2D.flip_h = true
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		$AnimatedSprite2D.play("default")

	move_and_slide()

@rpc("any_peer","call_local")
func fire():
	var bullet = bullet.instantiate()
	bullet.global_position = $GunRotation/BulletSpawn.global_position
	bullet.rotation = $GunRotation.rotation
	get_tree().root.add_child(bullet)
