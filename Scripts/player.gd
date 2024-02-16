extends CharacterBody2D

var health = 100.0
var is_dead = false

signal health_depleted

const SPEED = 400.0
const JUMP_VELOCITY = -1000.0

# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = 2000 #ProjectSettings.get_setting("physics/2d/default_gravity")
var can_shoot = false

@export var bullet : PackedScene

func _ready():
	$MultiplayerSynchronizer.set_multiplayer_authority(str(name).to_int())
	for i in GameManager.players:
		if i == $MultiplayerSynchronizer.get_multiplayer_authority():
			$Label.text = GameManager.players[i].name
	$ProgressBar.value = health
	
	if $MultiplayerSynchronizer.get_multiplayer_authority() != multiplayer.get_unique_id():
		$Camera2D.enabled = false
	else:
		$Camera2D.enabled = true
	
	GameManager.players[$MultiplayerSynchronizer.get_multiplayer_authority()].alive = true 

func _physics_process(delta):
	if $MultiplayerSynchronizer.get_multiplayer_authority() != multiplayer.get_unique_id():
		return
		
	if is_dead:
		return
	# Add the gravity.
	if not is_on_floor():
		velocity.y += gravity * delta

	$HandPivot.look_at(get_global_mouse_position())
	
	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	if Input.is_action_just_pressed("fire") and can_shoot:
		fire.rpc(get_global_mouse_position())

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var direction = Input.get_axis("ui_left", "ui_right")
	if direction:
		velocity.x = direction * SPEED
		if  velocity.x<0:
			$Sprite2D.flip_h = true
		else:
			$Sprite2D.flip_h = false
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)

	move_and_slide()
	#%ProgressBar.value = health

@rpc("any_peer","call_local")
func fire(direction):
	var bullet = bullet.instantiate()
	bullet.global_position = $HandPivot/ArrowSpawn.global_position
	bullet.dir = direction - $HandPivot/ArrowSpawn.global_position
	get_tree().root.add_child(bullet)

@rpc("any_peer","call_local")
func take_damage():
	if health > 0:
		health -= 30
	if health < 0:
		is_dead = true
		GameManager.players[$MultiplayerSynchronizer.get_multiplayer_authority()].alive = false
		$AnimationPlayer.play("die")
	
		health_depleted.emit()
	print("total_health = ",health)
	$ProgressBar.value = (health)


func _on_timer_timeout():
	can_shoot = true
