extends State

func enter():
	pass
	#if fsm.previous_state == "fall":
		#obj.play("ground")
		#obj.queue("idle")
	#else:
		#obj.play("idle")

func physics_update(delta):
	obj.update_velocity(delta)
	obj.move_and_slide()
	if not obj.is_on_floor():
		change_state("fall")
	elif obj.get_jump_input():
		change_state("jump")
	elif obj.get_input_x() != 0:
		change_state("run")
	#elif obj.get_down_input():
	#	change_state("crouch")

func exit():
	obj.clear_queue()
