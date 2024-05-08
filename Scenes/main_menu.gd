extends Control

@onready var main_menu = $MarginContainer/MainMenu
@onready var host_screen = $MarginContainer/HostScreen
@onready var join_screen = $MarginContainer/JoinScreen
@onready var lobby_screen = $MarginContainer/LobbyScreen
@onready var settings_screen = $MarginContainer/SettingsScreen
@onready var host_player_name_line_edit = $MarginContainer/HostScreen/GridContainer/HostPlayerLineEdit
@onready var join_player_name_line_edit = $MarginContainer/JoinScreen/GridContainer/JoinPlayerLineEdit
@onready var hobby_player_list = $MarginContainer/LobbyScreen/VBoxContainer/HBoxContainer/TextEdit
@onready var hobby_label = $MarginContainer/LobbyScreen/VBoxContainer/Label
@onready var color_selection_texture_rect = $MarginContainer/LobbyScreen/VBoxContainer2/MarginContainer/VBoxContainer/GridContainer/TextureRect

@export var address = "127.0.0.1"
@export var port = 8910

var peer
var color = "red"

var connected_players = 0

const red_player_texture = preload ("res://Assets/Players/Bodies/red_player.tres")
const yellow_player_texture = preload ("res://Assets/Players/Bodies/yellow_player.tres")
const green_player_texture = preload ("res://Assets/Players/Bodies/green_player.tres")
const purple_player_texture = preload ("res://Assets/Players/Bodies/purple_player.tres")

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
	#GameManager.players.erase(id)
	#var players = get_tree().get_nodes_in_group("Player")
	#for i in players:
	#	if i.name ==GameManager.players[id].name:
	#		i.queue_free()
	
func connected_to_server():
	print("Connected to server!")
	#if connected_players < 4:
	hobby_player_list.text = ""
	send_player_information.rpc_id(1, join_player_name_line_edit.text, multiplayer.get_unique_id(), color)

func connection_failed():
	print("Connection failed!")

@rpc("any_peer")
func send_player_information(name, id, color):
	if !GameManager.players.has(id):
		GameManager.players[id] = {
			"name": name,
			"id": id,
			"score": 0,
			"color": color
		}
		hobby_player_list.text += GameManager.players[id].name + "\n"
		connected_players += 1
		hobby_label.text = "Connected Players (" + str(connected_players) + "/4) ..."
	if multiplayer.is_server():
		for i in GameManager.players:
			send_player_information.rpc(GameManager.players[i].name, i, GameManager.players[i].color)

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
	send_player_information(host_player_name_line_edit.text, multiplayer.get_unique_id(), color)

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

func _on_left_color_button_pressed():
	if color == "red":
		color = "yellow"
		print("yellow")
		color_selection_texture_rect.texture = yellow_player_texture
		update_players_color.rpc(multiplayer.get_unique_id(), color)
	elif color == "yellow":
		color = "green"
		print("green")
		color_selection_texture_rect.texture = green_player_texture
		update_players_color.rpc(multiplayer.get_unique_id(), color)
	elif color == "green":
		color = "purple"
		print("purple")
		color_selection_texture_rect.texture = purple_player_texture
		update_players_color.rpc(multiplayer.get_unique_id(), color)
	else:
		color = "red"
		print("red")
		color_selection_texture_rect.texture = red_player_texture
		update_players_color.rpc(multiplayer.get_unique_id(), color)

func _on_right_color_button_pressed():
	if color == "red":
		color = "purple"
		print("purple")
		color_selection_texture_rect.texture = purple_player_texture
		update_players_color.rpc(multiplayer.get_unique_id(), color)
	elif color == "purple":
		color = "green"
		print("green")
		color_selection_texture_rect.texture = green_player_texture
		update_players_color.rpc(multiplayer.get_unique_id(), color)
	elif color == "green":
		color = "yellow"
		print("yellow")
		color_selection_texture_rect.texture = yellow_player_texture
		update_players_color.rpc(multiplayer.get_unique_id(), color)
	else:
		color = "red"
		print("red")
		color_selection_texture_rect.texture = red_player_texture
		update_players_color.rpc(multiplayer.get_unique_id(), color)

@rpc("any_peer", "call_local")
func update_players_color(id, colors):
	print("Updating player ", id, " color to ", colors)
	GameManager.players[id].color = colors
	


func _on_settings_button_pressed():
	main_menu.hide()
	settings_screen.show()

func _on_back_button_pressed():
	main_menu.show()
	settings_screen.hide()


func _on_sfx_slider_value_changed(value:float):
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), linear_to_db(value))
	AudioServer.set_bus_mute(AudioServer.get_bus_index("SFX"), value < 0.05)

func _on_music_slider_value_changed(value:float):
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(value))
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"), value < 0.05)

func _on_audio_stream_player_2d_finished():
	$AudioStreamPlayer2D.play()
