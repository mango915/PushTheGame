extends Node2D

#var player = get_parent()
var shooting_force = 0

@export var arrow: PackedScene

const red_hand = preload("res://Assets/red_hand.tres")
const yellow_hand = preload("res://Assets/yellow_hand.tres")
const green_hand = preload("res://Assets/green_hand.tres")

# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta):
	
	if get_parent().get_parent().get_node("MultiplayerSynchronizer").get_multiplayer_authority() != multiplayer.get_unique_id():
		return
		
	if get_parent().get_parent().is_dead:
		return
		
	look_at(get_global_mouse_position())
	
	if Input.is_action_pressed("fire") and get_parent().get_parent().can_shoot:
		shooting_force += 50
		
	if Input.is_action_just_released("fire") and get_parent().get_parent().can_shoot:
		print("shooting_force = ", shooting_force)
		#get_parent().velocity.x -= 500
		fire. rpc (get_global_mouse_position(), shooting_force)
		shooting_force = 300

@rpc("any_peer", "call_local")
func fire(direction, shooting_force):
	var arrow = arrow.instantiate()
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
