extends Node2D

@onready var animation_player = $AnimationPlayer
@onready var audio_player = $AudioStreamPlayer2D

const red_hand = preload("res://Assets/Players/Hands/red_hand.tres")
const yellow_hand = preload("res://Assets/Players/Hands/yellow_hand.tres")
const green_hand = preload("res://Assets/Players/Hands/green_hand.tres")
const purple_hand = preload("res://Assets/Players/Hands/purple_hand.tres")

# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _physics_process(delta):
		
	if get_parent().get_parent().get_node("MultiplayerSynchronizer").get_multiplayer_authority() != multiplayer.get_unique_id():
		return
		
	if get_parent().get_parent().is_dead:
		return
	
	#var dir = get_global_mouse_position() - global_position
	var dir = get_parent().get_parent().get_input_x()
	if dir < 0:
		scale = Vector2( - 1, 1)
	elif dir > 0:
		scale = Vector2(1, 1)

	if Input.is_action_just_pressed("fire") and get_parent().get_parent().can_shoot:
		punch.rpc()

@rpc("any_peer", "call_local")
func punch():
	audio_player.play()
	animation_player.play("punch")


func _on_area_2d_body_entered(body:Node2D):
	if body.has_method("take_damage") and multiplayer.is_server():
		body.take_damage(5)


func set_color(color):
	if color == "red":
		$Hand.texture = red_hand
	elif color == "yellow":
		$Hand.texture = yellow_hand
	elif color == "green":
		$Hand.texture = green_hand
	elif color == "purple":
		$Hand.texture = purple_hand
