extends State

@onready var coyote_timer = $CoyoteTimer
var can_double_jump = false
var can_wall_jump = false

func enter():
	#obj.play("fall")
	if fsm.previous_state != "jump" and fsm.previous_state != "doublejump" and fsm.previous_state != "walljump":
		coyote_timer.start()
		can_double_jump = true
	elif fsm.previous_state == "jump":
		can_double_jump = true
		can_wall_jump = true
	elif fsm.previous_state == "doublejump":
		#print("set can_double_jump and can_wall_jump to false")
		can_double_jump = false
		can_wall_jump = false
	elif fsm.previous_state == "walljump":
		#print("set can_wall_jump to false")
		can_double_jump = false
		can_wall_jump = false
		#obj.jump_buffer_timer.start()
	
	#obj.jump_buffer_timer.start()

func physics_update(delta):
	obj.update_velocity(delta)
	obj.move_and_slide()
	if not coyote_timer.is_stopped() and obj.get_jump_input():
		change_state("jump")
	elif can_wall_jump and obj.get_jump_input() and obj.is_next_to_wall():
		change_state("walljump")
	elif can_double_jump and obj.get_jump_input():
		change_state("doublejump")
	elif obj.is_on_floor():
		if not obj.jump_buffer_timer.is_stopped():
			change_state("jump")
		else:
			change_state("run" if obj.get_input_x() != 0 else "idle")
