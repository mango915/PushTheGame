extends CharacterBody2D
class_name Player_FSM_new

const ACCELERATION = 5000.0
const MAX_SPEED = 500.0
const JUMP_SPEED = -1800.0

const GRAVITY = 4500
const FALL_GRAVITY = 2300
const TERMINAL_VELOCITY = 900

const AIR_MULTIPLIER = 0.5

@onready var fsm = $FSM
@onready var ap = $AnimationPlayer
@onready var s = $Sprite2D
@onready var jump_buffer_timer = $JumpBufferTimer

var health = 100.0
var is_dead = false

signal health_depleted

#const SPEED = 400.0
#const JUMP_VELOCITY = -1000.0

# Get the gravity from the project settings to be synced with RigidBody nodes.
#var gravity = 2000 #ProjectSettings.get_setting("physics/2d/default_gravity")
var can_shoot = false
var shooting_force = 0

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
	
	fsm.change_state("idle") 

func _physics_process(delta):
	
	if $MultiplayerSynchronizer.get_multiplayer_authority() != multiplayer.get_unique_id():
		return
		
	if is_dead:
		return
		
	if get_jump_input():
		jump_buffer_timer.start()
	sync_direction()
	fsm.physics_update(delta)
	
	# Handle shooting
	$HandPivot.look_at(get_global_mouse_position())
	
	if Input.is_action_pressed("fire") and can_shoot:
		shooting_force += 50
		
	if Input.is_action_just_released("fire") and can_shoot:
		print("shooting_force = ",shooting_force)
		fire.rpc(get_global_mouse_position(),shooting_force)
		shooting_force = 0

@rpc("any_peer","call_local")
func fire(direction, shooting_force):
	var bullet = bullet.instantiate()
	bullet.global_position = $HandPivot/ArrowSpawn.global_position
	bullet.dir = direction - $HandPivot/ArrowSpawn.global_position
	bullet.speed = shooting_force
	get_tree().root.add_child(bullet)

@rpc("any_peer","call_local")
func take_damage():
	if health > 0:
		health -= 100
		print("total_health = ",health)
		$ProgressBar.value = health
		
	if health <= 0:
		is_dead = true
		can_shoot = false
		GameManager.players[$MultiplayerSynchronizer.get_multiplayer_authority()].alive = false
		$AnimationPlayer.play("die")
		health_depleted.emit()
		$ProgressBar.value = 0
	if multiplayer.is_server():
		for i in GameManager.players:
			if i != 1:
				self.take_damage.rpc_id(i)


func sync_direction():
	var input_x = get_input_x()
	if input_x == 0: return
	s.flip_h = input_x == -1

func update_velocity(delta):
	velocity.y = move_toward(velocity.y, TERMINAL_VELOCITY, (GRAVITY if fsm.current_state == "jump" else FALL_GRAVITY) * delta)
	velocity.x = move_toward(velocity.x, get_input_x() * MAX_SPEED, (1 if is_on_floor() else AIR_MULTIPLIER) * ACCELERATION * delta)
	print("player velocity: %s" % velocity)

func play(anim):
	ap.play(anim)

func queue(anim):
	ap.queue(anim)

func clear_queue():
	ap.clear_queue()

func get_input_x():
	return Input.get_axis("ui_left", "ui_right")

func get_jump_input():
	return Input.is_action_just_pressed("ui_accept")

func get_jump_hold():
	return Input.is_action_pressed("ui_accept")


func _on_timer_timeout():
	can_shoot = true
