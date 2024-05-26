extends State

func enter():
	#if fsm.previous_state == "fall":
		#obj.play("ground")
		#obj.queue("idle")
	obj.play.rpc("crouch")
	#obj.start_descend_platform_timer()

func physics_update(delta):
	obj.update_velocity(delta)
	obj.move_and_slide()
	#if not obj.is_on_floor():
	#	change_state("fall")
	#elif obj.get_jump_input():
	#	change_state("jump")
	if obj.get_input_x() != 0:
		change_state("run")
	elif not obj.get_down_input():
		change_state("idle")

func exit():
	#obj.position.y -= 20
	obj.play_backwards.rpc("crouch")
	obj.clear_queue()
