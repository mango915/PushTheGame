extends Node
class_name FSM

var states := {}
var current_state
var previous_state
var current_state_node

func _ready():
	var obj = get_parent()
	for child in get_children():
		if child is State:
			child.fsm = self
			child.obj = obj
			states[child.name.to_lower()] = child
			
func physics_update(delta):
	if not current_state: return
	current_state_node.physics_update(delta)
	
func change_state(next_state):
	print("%s -> %s" % [current_state, next_state])
	if current_state:
		current_state_node.exit()
	previous_state = current_state
	current_state = next_state
	current_state_node = states[next_state]
	current_state_node.enter()
