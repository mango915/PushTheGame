extends Node
class_name State

var obj
var fsm

func enter():
	pass
	
func physics_update(_delta):
	pass

func exit():
	pass

func change_state(next_state):
	fsm.change_state(next_state)
