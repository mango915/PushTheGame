extends Control

@onready var main_menu = $MarginContainer/MainMenu
@onready var host_screen = $MarginContainer/HostScreen
@onready var join_screen = $MarginContainer/JoinScreen
@onready var lobby_screen = $MarginContainer/LobbyScreen
@onready var host_player_name_line_edit = $MarginContainer/HostScreen/GridContainer/HostPlayerLineEdit
@onready var join_player_name_line_edit = $MarginContainer/JoinScreen/GridContainer/JoinPlayerLineEdit
@onready var hobby_player_list = $MarginContainer/LobbyScreen/VBoxContainer/TextEdit
@export var address = "127.0.0.1"
@export var port = 8910

var peer

# Called when the node enters the scene tree for the first time.
func _ready():
	multiplayer.peer_connected.connect(peer_connected)
	multiplayer.peer_disconnected.connect(peer_disconnected)
	multiplayer.connected_to_server.connect(connected_to_server)
	multiplayer.connection_failed.connect(connection_failed)

func peer_connected(id):
	print("Player Connected: " + str(id))
	#if multiplayer.is_server():
		#send_player_information.rpc(GameManager.players[id].name, id)
	#	hobby_player_list.text += GameManager.players[id].name + "\n"

func peer_disconnected(id):
	print("Player disconnected: " + str(id))
	GameManager.players.erase(id)
	var players = get_tree().get_nodes_in_group("Player")
	for i in players:
		if i.name == str(id):
			i.queue_free()
	
func connected_to_server():
	print("Connected to server!")
	hobby_player_list.text = ""
	send_player_information.rpc_id(1, join_player_name_line_edit.text, multiplayer.get_unique_id())

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
		hobby_player_list.text += GameManager.players[id].name + "\n"
	if multiplayer.is_server():
		for i in GameManager.players:
			send_player_information.rpc(GameManager.players[i].name, i)

@rpc("any_peer", "call_local")
func start_game():
	var scene = load("res://Scenes/Levels/test_scene_4.tscn").instantiate()
	get_tree().root.add_child(scene)
	self.hide()

func _on_host_game_button_pressed():
	main_menu.hide()
	host_screen.show()

func _on_host_button_pressed():

	peer = ENetMultiplayerPeer.new()

	port = int(host_screen.get_node("GridContainer/PortLineEdit").text)
	
	var error = peer.create_server(port, 6)
	
	if error != OK:
		print("cannot host: " + error)
		return
		
	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	
	multiplayer.set_multiplayer_peer(peer)
	print("Waiting For Players")
	send_player_information(host_player_name_line_edit.text, multiplayer.get_unique_id())

	lobby_screen.show()
	hobby_player_list.text = host_player_name_line_edit.text + "\n"
	host_screen.hide()

func _on_join_button_pressed():
	address = $MarginContainer/JoinScreen/GridContainer/IpLineEdit.text
	port = int($MarginContainer/JoinScreen/GridContainer/PortLineEdit.text)

	peer = ENetMultiplayerPeer.new()
	peer.create_client(address, port)
	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	
	multiplayer.set_multiplayer_peer(peer)
	lobby_screen.show()
	join_screen.hide()

func _on_start_game_button_pressed():
	start_game.rpc()

func _on_exit_button_pressed():
	get_tree().quit()

func _on_join_game_button_pressed():
	main_menu.hide()
	join_screen.show()
