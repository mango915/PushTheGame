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
@onready var descend_platform_timer = $DescendPlatformTimer

var health = MAX_HEALTH
var is_dead = false

#var weapon = null
@export var weapon_scale = Vector2(1, 1)
@export var weapon_rotation = 0
@export var synchd_position = Vector2(0, 0)
@export var synchd_rotation = 0
@export var synchd_velocity = Vector2(0, 0)

var color = "red"

const melee_scene = preload("res://Scenes/Weapons/melee.tscn")

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
		fsm.change_state("idle")
		$Camera2D.enabled = true
	
	GameManager.players[$MultiplayerSynchronizer.get_multiplayer_authority()].alive = true
	

func _physics_process(delta):
	
	if $MultiplayerSynchronizer.get_multiplayer_authority() != multiplayer.get_unique_id():
		$WeaponAttach.get_child(0).scale = weapon_scale
		$WeaponAttach.get_child(0).rotation = weapon_rotation
		rotation = synchd_rotation
		global_position = global_position.lerp(synchd_position+synchd_velocity*delta, delta*10)
		
		return
		
	if is_dead:
		return
		
	if get_jump_input():
		jump_buffer_timer.start()
	sync_direction()
	fsm.physics_update(delta)

	weapon_scale = $WeaponAttach.get_child(0).scale
	weapon_rotation = $WeaponAttach.get_child(0).rotation
	synchd_position = global_position
	synchd_rotation = rotation
	synchd_velocity = velocity
	
func _input(event):
	if $MultiplayerSynchronizer.get_multiplayer_authority() != multiplayer.get_unique_id():
		return
	if event.is_action_pressed("ui_down") and not descend_platform_timer.is_stopped():
		position.y += 5
	if event.is_action_released("ui_down"):
		descend_platform_timer.start()
	if event.is_action_pressed("pickup"):
		print("pickup")
		print(is_next_to_wall())
		try_to_pickup_object.rpc_id(1)
	if event.is_action_pressed("drop_weapon"):
		drop_weapon.rpc_id(1)

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
	$RayCast2D.target_position = (Vector2(89,0) if input_x == 1 else Vector2(-89,0))

func update_velocity(delta):
	velocity.y = move_toward(velocity.y, TERMINAL_VELOCITY, (GRAVITY if fsm.current_state == "jump" else FALL_GRAVITY) * delta)
	velocity.x = move_toward(velocity.x,(1 if fsm.current_state != "crouch" else 0.4) * get_input_x() * MAX_SPEED, (1 if is_on_floor() else AIR_MULTIPLIER) * ACCELERATION * delta)
	#print("player velocity: %s" % velocity)

@rpc("any_peer", "call_local")
func play(anim):
	ap.play(anim)
	if multiplayer.is_server():
		for i in GameManager.players:
			if i != 1:
				self.play.rpc_id(i, anim)
	
@rpc("any_peer", "call_local")
func play_backwards(anim):
	ap.play_backwards(anim)
	if multiplayer.is_server():
		for i in GameManager.players:
			if i != 1:
				self.play_backwards.rpc_id(i, anim)

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

func get_down_input():
	return Input.is_action_just_pressed("ui_down")

func get_down_hold():
	return Input.is_action_pressed("ui_down")

func _on_timer_timeout():
	can_shoot = true

func start_descend_platform_timer():
	descend_platform_timer.start()

func _on_hurt_box_body_entered(_body):
	if multiplayer.is_server() and health > 0:
		print("Damaged from environment!")
		self.take_damage(25)

func attach_weapon(new_weapon):
	new_weapon.set_color(color)
	$WeaponAttach.add_child(new_weapon, true)
	#weapon.global_position = Vector2(0, 0)
	#weapon_scale = $WeaponAttach.scale
	#weapon_rotation = $WeaponAttach.rotation

@rpc("any_peer", "call_local")
func try_to_pickup_object():
	var bodies = $InteractionArea.get_overlapping_areas()
	var body_to_pickup = null
	for body in bodies:
		print("body = ", body)
		if body.has_method("pickup"):
			if body_to_pickup == null:
				body_to_pickup = body
			else:
				if body.global_position.distance_to(global_position) < body_to_pickup.global_position.distance_to(global_position):
					body_to_pickup = body
	if body_to_pickup != null:
		body_to_pickup.pickup(self)

	if multiplayer.is_server():
		for i in GameManager.players:
			if i != 1:
				self.try_to_pickup_object.rpc_id(i)

@rpc("any_peer", "call_local")
func drop_weapon():
	if $WeaponAttach.get_child_count() > 0:
		var weapon = $WeaponAttach.get_child(0)
		print("dropping weapon", weapon.name)
		if weapon.name == "Gun":
			var gun_pickup = preload("res://Scenes/Pickups/gun_pickup.tscn").instantiate()
			gun_pickup.global_position = weapon.global_position
			gun_pickup.is_dropped_weapon = true
			get_parent().get_parent().add_child(gun_pickup, true)
		elif weapon.name == "Bow":
			var bow_pickup = preload("res://Scenes/Pickups/bow_pickup.tscn").instantiate()
			bow_pickup.global_position = weapon.global_position
			bow_pickup.is_dropped_weapon = true
			get_parent().get_parent().add_child(bow_pickup, true)
		
		weapon.queue_free()
		var melee = melee_scene.instantiate()
		attach_weapon(melee)

		if multiplayer.is_server():
			for i in GameManager.players:
				if i != 1:
					self.drop_weapon.rpc_id(i)

func is_next_to_wall():
	return $RayCast2D.is_colliding()
