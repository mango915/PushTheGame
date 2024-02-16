extends Control

@export var address = "127.0.0.1"
@export var port = 8910

var peer

# Called when the node enters the scene tree for the first time.
func _ready():
	multiplayer.peer_connected.connect(peer_connected)
	multiplayer.peer_disconnected.connect(peer_disconnected)
	multiplayer.connected_to_server.connect(connected_to_server)
	multiplayer.connection_failed.connect(connection_failed)
	
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass

func peer_connected(id):
	print("Player Connected: " + str(id))

func peer_disconnected(id):
	print("Player disconnected: " + str(id))
	GameManager.players.erase(id)
	var players = get_tree().get_nodes_in_group("Player")
	for i in players:
		if i.name == str(id):
			i.queue_free()
	
func connected_to_server():
	print("Connected to server!")
	send_player_information.rpc_id(1,$LineEdit.text, multiplayer.get_unique_id())

func connection_failed():
	print("Connection failed!")


@rpc("any_peer")
func send_player_information(name, id):
	if !GameManager.players.has(id):
		GameManager.players[id] = {
			"name": name,
			"id": id,
			"score": 0
		}
	if multiplayer.is_server():
		for i in GameManager.players:
			send_player_information.rpc(GameManager.players[i].name, i)

@rpc("any_peer","call_local")
func start_game():
	var scene = load("res://Scenes/test_scene_2.tscn").instantiate()
	get_tree().root.add_child(scene)
	self.hide()

func _on_host_button_down():
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port, 6)
	
	if error != OK:
		print("cannot host: "+ error)
		return
		
	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	
	multiplayer.set_multiplayer_peer(peer)
	print("Waiting For Players")
	send_player_information($LineEdit.text, multiplayer.get_unique_id())
	
	pass # Replace with function body.


func _on_join_button_down():
	peer = ENetMultiplayerPeer.new()
	peer.create_client(address,port)
	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	multiplayer.set_multiplayer_peer(peer)
	
	pass # Replace with function body.


func _on_start_game_button_down():
	start_game.rpc()
	
	pass # Replace with function body.
