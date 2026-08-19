extends "res://actors/player-states/Idle.gd"

func _state_enter(info: Dictionary) -> void:
	host.play_animation("Walk")
	if info.has('input_vector'):
		do_move(info['input_vector'])


func _state_physics_process(delta: float) -> void:
	_check_pickup_or_throw_or_use()
	
	var input_vector = _get_player_input_vector()
	if host.input_buffer.is_action_just_pressed("jump") and not host.jump_blocked:
		if host.is_on_floor():
			get_parent().change_state("Jump", {
				"input_vector": input_vector,
			})
			return
	elif host.input_buffer.is_action_pressed("down") and host.is_on_floor():
		if abs(host.vector.x) > 10.0:
			get_parent().change_state("Slide")
		else:
			get_parent().change_state("Duck")
		return
	elif input_vector == Vector2.ZERO:
		get_parent().change_state("Idle")
		return
	
	do_move(input_vector)
	
	if host.vector.y > 0:
		get_parent().change_state("Fall")
		return

# Offered by the airborne states (Fall, Jump): pressing jump while pressed
# against a wall kicks off it instead of doing nothing.
#
# Returns true when the state changed, so the caller must stop processing --
# WallJump has already set the velocity this frame and anything after would
# stomp it. Deliberately NOT called from WallJump itself, which inherits this.
func _try_wall_jump() -> bool:
	if not host.input_buffer.is_action_just_pressed("jump"):
		return false
	if not host.can_wall_jump():
		return false
	get_parent().change_state("WallJump", { "wall_normal": host.get_wall_normal() })
	return true

func do_flip_sprite(input_vector: Vector2) -> void:
	if input_vector.x < 0:
		host.flip_h = true
	elif input_vector.x > 0:
		host.flip_h = false

func do_move(input_vector: Vector2) -> void:
	do_flip_sprite(input_vector)
	
	# Accelerate to top speed.
	var delta = get_physics_process_delta_time()
	if input_vector.x > 0:
		host.vector.x = min(input_vector.x * host.speed, host.vector.x + (host.acceleration * delta))
	elif input_vector.x < 0:
		host.vector.x = max(input_vector.x * host.speed, host.vector.x - (host.acceleration * delta))
	else:
		_decelerate_to_zero(delta)


