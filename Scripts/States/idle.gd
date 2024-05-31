extends State

@onready var crouching_timer = $CrouchingTimer

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
	elif obj.get_down_input() and crouching_timer.is_stopped():
		print("crouch")
		crouching_timer.start()
		#change_state("crouch")

func exit():
	obj.clear_queue()

func _on_crouching_timer_timeout():
	if fsm.current_state == "idle" and obj.is_on_floor():
		change_state("crouch")
