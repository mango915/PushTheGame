extends "res://actors/player-states/Move.gd"

func _state_enter(info: Dictionary) -> void:
	host.play_animation("Fall")

func _state_exit() -> void:
	host.show_gliding = false

func _state_physics_process(delta: float) -> void:
	_check_pickup_or_throw_or_use()

	if _try_wall_jump():
		return

	var input_vector = _get_player_input_vector()

	# Stepped off a ledge a moment ago: the jump is still owed.
	if host.input_buffer.is_action_just_pressed("jump") and host.can_coyote_jump():
		host.consume_coyote()
		get_parent().change_state("Jump", { "input_vector": input_vector })
		return

	# vector.y >= 0: is_on_floor() reflects the LAST move_and_slide, so a body
	# still travelling upward has not landed.
	if host.is_on_floor() and host.vector.y >= 0.0:
		# Every landing gets the impact, not just the one that happens to end
		# standing still. Fall -> Move plays "Walk" and never touches the "Land"
		# animation, so a running landing used to arrive weightless -- which is
		# most landings in a platformer.
		host.land_impact()
		# Asked to jump just before touching down: honour it now rather than
		# throwing the press away.
		if host.consume_buffered_jump():
			get_parent().change_state("Jump", { "input_vector": input_vector })
			return
		if abs(input_vector.x) > 0:
			get_parent().change_state("Move", { input_vector = input_vector })
		else:
			get_parent().change_state("Idle", { landing = true })
		return
	
	do_move(input_vector)
	
	# If the player presses the jump key before landing, then glide.
	if host.input_buffer.is_action_pressed("jump"):
		host.vector.y = -host.glide_speed
		host.show_gliding = true
		host.play_animation("Glide")
	else:
		host.play_animation("Fall")
		
