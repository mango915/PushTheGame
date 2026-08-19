extends "res://actors/player-states/Move.gd"

# Kicking off a wall.
#
# Ported as a MECHANIC from the compa_dev branch, not as code: that branch is a
# separate rewrite with its own FSM, its own player and an HP model this game
# does not have, so nothing there could be lifted directly. What transferred is
# the shape of the move -- launch up, shove away from the wall, and cut the jump
# short if the button is released -- expressed against this game's state machine
# and its replayed-input sync.
#
# The shove away from the wall is the part that matters. Without it a wall is a
# free ladder: you would climb any vertical surface indefinitely, and every
# arena here is laid out against a documented jump budget that build_maps.gd
# reasons about and MapReachabilityTest proves. Being pushed off means a climb
# costs you horizontal position and has to be re-earned.

func _state_enter(info: Dictionary) -> void:
	host.play_animation("Jump")
	host.sounds.play("Jump")

	# Away from the wall. The normal travels in the state info rather than being
	# read from the host, because a remote player is simulated from a replayed
	# input buffer and is not necessarily touching the same wall on the frame
	# this state arrives -- Player.sync_state_info carries it over the wire.
	var normal: Vector2 = info.get("wall_normal", Vector2.ZERO)
	if normal == Vector2.ZERO:
		normal = host.get_wall_normal()

	host.vector.y = -host.wall_jump_speed
	host.vector.x = signf(normal.x) * host.wall_jump_push

	# Face the way we are now travelling, not the wall we just left.
	if normal.x != 0.0:
		host.flip_h = normal.x < 0.0

func _state_physics_process(delta: float) -> void:
	_check_pickup_or_throw_or_use()

	if host.is_on_floor():
		get_parent().change_state("Idle", { landing = true })
		return

	# Air control, but only after the kick has carried us clear -- steering back
	# into the wall on the first frames would cancel the push and re-enable the
	# ladder this move exists to avoid.
	var input_vector = _get_player_input_vector()
	if signf(input_vector.x) == signf(host.vector.x) or host.vector.x == 0.0:
		do_move(input_vector)

	# Releasing jump early cuts it short, exactly as a normal jump does.
	if host.input_buffer.is_action_just_released("jump"):
		if host.vector.y < 0.0:
			host.vector.y = 0.0

	if host.vector.y >= 0.0:
		get_parent().change_state("Fall")
