extends "res://actors/player-states/Move.gd"

func _state_enter(info: Dictionary) -> void:
	host.play_animation("Duck")
	host.ducking_collision_shape.set_deferred('disabled', false)
	host.standing_collision_shape.set_deferred('disabled', true)

func _state_exit() -> void:
	host.ducking_collision_shape.set_deferred('disabled', true)
	host.standing_collision_shape.set_deferred('disabled', false)

func _state_physics_process(delta: float) -> void:
	_check_pickup_or_throw_or_use()
	
	var input_vector = _get_player_input_vector()
	do_flip_sprite(input_vector)
	
	_decelerate_to_zero(delta)
	
	if not host.input_buffer.is_action_pressed("down") or not host.is_on_floor():
		get_parent().change_state("Idle")
	elif host.input_buffer.is_action_just_pressed("jump"):
		# Down + jump drops through a one-way platform.
		#
		# This used to set the flag on the jump frame and clear it again on the
		# NEXT one, on the theory that a player who had not moved by then was not
		# standing on a one-way platform. From rest they never had: gravity needs
		# a couple of frames to carry them the 16px through the collision band,
		# so the mask was restored before they had left and drop-through simply
		# never worked. It is cleared by PassThroughDetectorArea once they are
		# genuinely clear, with a timeout as a backstop.
		host.drop_through()
