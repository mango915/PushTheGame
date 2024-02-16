extends Node2D

@export var player_scene : PackedScene
@export var textures : Resource
var alive_players = 0
# Called when the node enters the scene tree for the first time.
func _ready():
	var index = 0
	for i in GameManager.players:
		var current_player = player_scene.instantiate()
		current_player.name = str(GameManager.players[i].id)
		#current_player.get_node("Sprite2D").texture = textures
		add_child(current_player)
		current_player.health_depleted.connect(_on_player_died)
		for spawn in get_tree().get_nodes_in_group("PlayerSpawnPoint"):
			if spawn.name == str(index) :
				current_player.global_position = spawn.global_position
		index += 1
		alive_players +=1
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass
	
func _on_player_died():
	alive_players -= 1
	if alive_players == 1:
		print("Finished the round!")
		%GameOver.visible = true
		if GameManager.players[multiplayer.get_unique_id()].alive:
			GameManager.players[multiplayer.get_unique_id()].score += 1
			%GameOver/Label.text = "You Win! \n current score : " + str(GameManager.players[multiplayer.get_unique_id()].score)
		#get_tree().paused = true
	
		


func _on_button_button_down():
	print("game should restart")
	start_next_game.rpc()


@rpc("any_peer","call_local")
func start_next_game():
	var scene = load("res://Scenes/test_scene_2.tscn").instantiate()
	get_tree().root.add_child(scene)
	self.queue_free()
	#self.hide()
