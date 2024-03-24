extends State

var variable_jump_height

func enter():
	#obj.play("jump")
	obj.velocity.y = Player_FSM_new.JUMP_SPEED / 2
	#obj.velocity.x += Player_FSM_new.MAX_SPEED * obj.get_input_x()
	variable_jump_height = false
	obj.jump_buffer_timer.stop()

func physics_update(delta):
	if not variable_jump_height and not obj.get_jump_hold():
		obj.velocity.y /= 2
		variable_jump_height = true
	obj.update_velocity(delta)
	obj.move_and_slide()
	if obj.velocity.y >= 0:
		change_state("fall")
