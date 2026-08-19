extends Node

func play(name: String):
	var node = get_node(name)
	assert(node != null, "No sound with name " + name)
	
	if node is AudioStreamPlayer:
		node.play()
		return node
	elif node is Node:
		var players = []
		for child in node.get_children():
			if child is AudioStreamPlayer:
				players.append(child)
		if players.is_empty():
			push_warning("No AudioStreamPlayer children under sound group " + name)
			return null
		players.shuffle()
		players[0].play()
		return players[0]
