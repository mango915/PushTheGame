extends State

var down_released = false

func enter():
	#if fsm.previous_state == "fall":
		#obj.play("ground")
		#obj.queue("idle")
	obj.play.rpc_id(1,"crouch")
	#obj.start_descend_platform_timer()

func physics_update(delta):
	obj.update_velocity(delta)
	obj.move_and_slide()
	#if not obj.is_on_floor():
	#	change_state("fall")
	#elif obj.get_jump_input():
	#	change_state("jump")
	if obj.get_input_x() != 0 and not obj.get_crouch_input():
		change_state("run")
	elif not obj.get_crouch_input(): # and not obj.descend_platform_timer.is_stopped():
		#down_released = true
		change_state("idle")

func exit():
	#obj.position.y -= 100
	#var tween = create_tween()
	#tween.tween_property(obj, "position", Vector2(obj.position.x, obj.position.y - 30), 0.1)
	obj.play_backwards.rpc_id(1,"crouch")
	obj.clear_queue()
