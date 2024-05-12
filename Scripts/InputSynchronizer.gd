extends MultiplayerSynchronizer

# Set via RPC to simulate is_action_just_pressed.
@export var jumping := false
@export var just_jumped := false

# Synchronized property.
@export var direction := float()

@export var down := false
@export var pickup := false

func _ready():
	# Only process for the local player.
	set_process(get_multiplayer_authority() == multiplayer.get_unique_id())


@rpc("call_local")
func jump():
	jumping = true
	if just_jumped == false:
		just_jumped = true

@rpc("call_local")
func stop_jump():
	jumping = false

@rpc("call_local")
func stop_just_jumping():
	just_jumped = false

func _process(delta):
	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	direction = Input.get_axis("ui_left", "ui_right")
	#jumping = Input.is_action_pressed("ui_accept")
	#just_jumped = Input.is_action_just_pressed("ui_accept")
	down =	Input.is_action_pressed("ui_down")
	pickup = Input.is_action_pressed("pickup")

	if just_jumped:
		stop_just_jumping.rpc()

	if Input.is_action_just_pressed("ui_accept"):
		print("Just pressed jump!")
		jump.rpc()

	if Input.is_action_just_released("ui_accept"):
		stop_jump.rpc()
