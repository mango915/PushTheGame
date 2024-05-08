extends Node2D

@export var player_scene: PackedScene
@export var weapon_scene: PackedScene
@export var next_scene: PackedScene


const red_player_texture = preload ("res://Assets/Players/Bodies/red_player.tres")
const yellow_player_texture = preload ("res://Assets/Players/Bodies/yellow_player.tres")
const green_player_texture = preload ("res://Assets/Players/Bodies/green_player.tres")
const purple_player_texture = preload ("res://Assets/Players/Bodies/purple_player.tres")

var alive_players = 0
var players = {}

# Called when the node enters the scene tree for the first time.
func _ready():
	var index = 0

	multiplayer.peer_disconnected.connect(peer_disconnected)

	for i in GameManager.players:
		var current_player = player_scene.instantiate()

		current_player.name = str(GameManager.players[i].id)
		players[GameManager.players[i].id] = current_player

		print("player color: " + GameManager.players[i].color)
		if GameManager.players[i].color == "red":
			current_player.color = "red"
			current_player.get_node("Sprite2D").texture = red_player_texture
		elif GameManager.players[i].color == "yellow":
			current_player.color = "yellow"
			current_player.get_node("Sprite2D").texture = yellow_player_texture
		elif GameManager.players[i].color == "green":
			current_player.color = "green"
			current_player.get_node("Sprite2D").texture = green_player_texture
		elif GameManager.players[i].color == "purple":
			current_player.color = "purple"
			current_player.get_node("Sprite2D").texture = purple_player_texture

		current_player.attach_weapon(weapon_scene.instantiate())


		add_child(current_player)
		current_player.health_depleted.connect(_on_player_died)
		for spawn in get_tree().get_nodes_in_group("PlayerSpawnPoint"):
			if spawn.name == str(index):
				current_player.global_position = spawn.global_position
		index += 1
		alive_players += 1

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass


func peer_disconnected(id):
	print("Player disconnected: " + str(id))
	players[id].queue_free()
	GameManager.players.erase(id)
	


func _on_player_died():
	alive_players -= 1
	if not GameManager.players[multiplayer.get_unique_id()].alive:
		%GameOver.visible = true
		players[multiplayer.get_unique_id()].can_shoot = false
		%GameOver/Label.text = "You Lose! \n current score : " + str(GameManager.players[multiplayer.get_unique_id()].score)
		# disable %GameOver/Button
		%GameOver/Button.disabled = true
	if alive_players == 1:
		print("Finished the round!")
		%GameOver.visible = true
		%GameOver/Button.disabled = false
		if GameManager.players[multiplayer.get_unique_id()].alive:
			players[multiplayer.get_unique_id()].can_shoot = false
			update_players_score.rpc(multiplayer.get_unique_id())
			#GameManager.players[multiplayer.get_unique_id()].score += 1
			%GameOver/Label.text = "You Win! \n current score : " + str(GameManager.players[multiplayer.get_unique_id()].score)
		#get_tree().paused = true

func _on_button_button_down():
	print("game should restart")
	start_next_game.rpc(randi_range(2, 4))

@rpc("any_peer", "call_local")
func start_next_game(scene_number):
	var scene_str = "res://Scenes/Levels/test_scene_"+str(scene_number)+".tscn"
	var scene = load(scene_str).instantiate()
	get_tree().root.add_child(scene)
	self.queue_free()
	#self.hide()

@rpc("any_peer", "call_local")
func update_players_score(id):
	GameManager.players[id].score += 1
	
