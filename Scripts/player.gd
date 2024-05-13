extends CharacterBody2D
class_name Player_FSM_new

const ACCELERATION = 5000.0
const MAX_SPEED = 800.0
const JUMP_SPEED = -1800.0

const GRAVITY = 4500
const FALL_GRAVITY = 2000
const TERMINAL_VELOCITY = 900

const AIR_MULTIPLIER = 0.5
const MAX_HEALTH = 100

@onready var fsm = $FSM
@onready var ap = $AnimationPlayer
@onready var s = $Sprite2D
@onready var jump_buffer_timer = $JumpBufferTimer

var health = MAX_HEALTH
var is_dead = false

var weapon = null
var weapon_scale = Vector2(1, 1)
var weapon_rotation = 0

var color = "red"

signal health_depleted

#const SPEED = 400.0
#const JUMP_VELOCITY = -1000.0

# Get the gravity from the project settings to be synced with RigidBody nodes.
#var gravity = 2000 #ProjectSettings.get_setting("physics/2d/default_gravity")
var can_shoot = false
#var shooting_force = 0

#@export var bullet : PackedScene

@export var player := 1 :
	set(id):
		player = id
		# Give authority over the player input to the appropriate peer.
		$MultiplayerSynchronizer.set_multiplayer_authority(id)

func _ready():
	print(name)
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
		$WeaponAttach.get_child(0).scale = weapon_scale
		$WeaponAttach.get_child(0).rotation = weapon_rotation
		return
		
	if is_dead:
		return
		
	if get_jump_input():
		jump_buffer_timer.start()
	sync_direction()
	fsm.physics_update(delta)

	weapon_scale = $WeaponAttach.get_child(0).scale
	weapon_rotation = $WeaponAttach.get_child(0).rotation
	
func _input(event):
	if $MultiplayerSynchronizer.get_multiplayer_authority() != multiplayer.get_unique_id():
		return
	if event.is_action_pressed("ui_down"):
		position.y += 1
	if event.is_action_pressed("pickup"):
		print("pickup")
		try_to_pickup_object.rpc_id(1)

@rpc("any_peer", "call_local")
func take_damage(dmg):
	if health > 0:
		health -= dmg
		print("total_health = ", health)
		$ProgressBar.value = health
		
	if health <= 0:
		is_dead = true
		can_shoot = false
		GameManager.players[$MultiplayerSynchronizer.get_multiplayer_authority()].alive = false
		disable_collider.call_deferred()
		$AnimationPlayer.play("die")
		health_depleted.emit()
		$ProgressBar.value = 0
	if multiplayer.is_server():
		for i in GameManager.players:
			if i != 1:
				self.take_damage.rpc_id(i, dmg)

func disable_collider():
	$CollisionShape2D.disabled = true
	$HurtBox/CollisionShape2D.disabled = true

@rpc("any_peer", "call_local")
func heal_damage():
	if health < MAX_HEALTH:
		health = min(health + 50, MAX_HEALTH)
		print("total_health = ", health)
		$ProgressBar.value = health
		
	if multiplayer.is_server():
		for i in GameManager.players:
			if i != 1:
				self.heal_damage.rpc_id(i)

func sync_direction():
	var input_x = get_input_x()
	if input_x == 0: return
	s.flip_h = input_x == - 1

func update_velocity(delta):
	velocity.y = move_toward(velocity.y, TERMINAL_VELOCITY, (GRAVITY if fsm.current_state == "jump" else FALL_GRAVITY) * delta)
	velocity.x = move_toward(velocity.x, get_input_x() * MAX_SPEED, (1 if is_on_floor() else AIR_MULTIPLIER) * ACCELERATION * delta)
	#print("player velocity: %s" % velocity)

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

func _on_hurt_box_body_entered(_body):
	if multiplayer.is_server() and health > 0:
		print("Damaged from environment!")
		self.take_damage(10)

func attach_weapon(new_weapon):
	new_weapon.set_color(color)
	$WeaponAttach.add_child(new_weapon)
	#weapon.global_position = Vector2(0, 0)
	#weapon_scale = $WeaponAttach.scale
	#weapon_rotation = $WeaponAttach.rotation

@rpc("any_peer", "call_local")
func try_to_pickup_object():
	var bodies = $InteractionArea.get_overlapping_areas()
	for body in bodies:
		print("body = ", body)
		if body.has_method("pickup"):
			body.pickup(self)
	if multiplayer.is_server():
		for i in GameManager.players:
			if i != 1:
				self.try_to_pickup_object.rpc_id(i)
			
