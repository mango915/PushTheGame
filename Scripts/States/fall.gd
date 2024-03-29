extends State

@onready var coyote_timer = $CoyoteTimer
var can_double_jump = false

func enter():
	#obj.play("fall")
	if fsm.previous_state != "jump" and fsm.previous_state != "doublejump":
		coyote_timer.start()
		can_double_jump = true
	elif fsm.previous_state == "jump":
		can_double_jump = true
	elif fsm.previous_state == "doublejump":
		can_double_jump = false
		#obj.jump_buffer_timer.start()
	
	#obj.jump_buffer_timer.start()

func physics_update(delta):
	obj.update_velocity(delta)
	obj.move_and_slide()
	if not coyote_timer.is_stopped() and obj.get_jump_input():
		change_state("jump")
	if can_double_jump and obj.get_jump_input():
		change_state("doublejump")
	elif obj.is_on_floor():
		if not obj.jump_buffer_timer.is_stopped():
			change_state("jump")
		else:
			change_state("run" if obj.get_input_x() != 0 else "idle")
