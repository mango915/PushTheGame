extends Node2D

#var player = get_parent()
var shooting_force = 0

@export var arrow: PackedScene
@onready var audio_player = $AudioStreamPlayer2D

const red_hand = preload("res://Assets/Players/Hands/red_hand.tres")
const yellow_hand = preload("res://Assets/Players/Hands/yellow_hand.tres")
const green_hand = preload("res://Assets/Players/Hands/green_hand.tres")
const purple_hand = preload("res://Assets/Players/Hands/purple_hand.tres")

var can_shoot = true
# Called when the node enters the scene tree for the first time.
func _ready():
	if get_parent().get_parent().get_node("MultiplayerSynchronizer").get_multiplayer_authority() != multiplayer.get_unique_id():
		$ProgressBar.hide()
	
func _process(delta):
		$ProgressBar.value = shooting_force / 1000.0
		$ProgressBar.rotation_degrees = -global_rotation_degrees

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta):
	
	if get_parent().get_parent().get_node("MultiplayerSynchronizer").get_multiplayer_authority() != multiplayer.get_unique_id():
		return
		
	if get_parent().get_parent().is_dead:
		return

	if Input.get_connected_joypads().size() == 0:
		look_at(get_global_mouse_position())
	else:
		var dir = get_parent().get_parent().get_input_x()
		if dir > 0:
			rotation_degrees = -45
		elif dir < 0:
			rotation_degrees = -135
	
	if Input.is_action_pressed("fire") and get_parent().get_parent().can_shoot:
		shooting_force = clamp(shooting_force + 20, 0, 3000)
		
	if Input.is_action_just_released("fire") and get_parent().get_parent().can_shoot:
		print("shooting_force = ", shooting_force)
		#get_parent().velocity.x -= 500
		
		if Input.get_connected_joypads().size() == 0:
			fire.rpc(get_global_mouse_position(), shooting_force)
		else:
			if rotation_degrees == -45:
				fire.rpc(Vector2(100,-100), shooting_force, true)
			elif rotation_degrees == -135:
				fire.rpc(Vector2(-100,-100), shooting_force, true)
			#else:
			#fire. rpc (, shooting_force)
		shooting_force = 300

@rpc("any_peer", "call_local")
func fire(direction, shooting_force, joypad_shooting=false):

	if not can_shoot:
		return

	audio_player.play()
	var arrow = arrow.instantiate()
	can_shoot = false
	$ShootingTimer.start()

	if joypad_shooting:
		arrow.global_position = $ArrowSpawn.global_position
		arrow.dir = direction
		arrow.speed = shooting_force
		get_tree().root.add_child(arrow)

	arrow.global_position = $ArrowSpawn.global_position
	arrow.dir = direction - $ArrowSpawn.global_position
	arrow.speed = shooting_force
	get_tree().root.add_child(arrow)

func set_color(color):
	if color == "red":
		$Hand1.texture = red_hand
		$Hand2.texture = red_hand
	elif color == "yellow":
		$Hand1.texture = yellow_hand
		$Hand2.texture = yellow_hand
	elif color == "green":
		$Hand1.texture = green_hand
		$Hand2.texture = green_hand
	elif color == "purple":
		$Hand1.texture = purple_hand
		$Hand2.texture = purple_hand

func _on_shooting_timer_timeout():
	can_shoot = true