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
@onready var host_button = $MarginContainer/HostScreen/HostButton
@onready var join_button = $MarginContainer/JoinScreen/JoinButton
@onready var start_game_button = $MarginContainer/LobbyScreen/VBoxContainer2/StartGameButton
@onready var music_slider = $MarginContainer/SettingsScreen/MarginContainer/GridContainer/MusicSlider
@onready var sfx_slider = $MarginContainer/SettingsScreen/MarginContainer/GridContainer/SFXSlider
@onready var invite_code_label = $MarginContainer/LobbyScreen/VBoxContainer/GridContainer/InviteCodeLabel
@onready var copy_button = $MarginContainer/LobbyScreen/VBoxContainer/GridContainer/Button


@export var address = "127.0.0.1"
@export var port = 8910

var generated_invite_code = ""

var user_prefs: UserPreferences

var peer
var color = "red"

var connected_players = 0
var ready_players = 0

const red_player_texture = preload ("res://Assets/Players/Bodies/red_player.tres")
const yellow_player_texture = preload ("res://Assets/Players/Bodies/yellow_player.tres")
const green_player_texture = preload ("res://Assets/Players/Bodies/green_player.tres")
const purple_player_texture = preload ("res://Assets/Players/Bodies/purple_player.tres")

# Called when the node enters the scene tree for the first time.
func _ready():
	user_prefs = UserPreferences.load_or_create()

	if music_slider:
		music_slider.value = user_prefs.music_audio_level
	if sfx_slider:
		sfx_slider.value = user_prefs.sfx_audio_level
	
	if address:
		$MarginContainer/JoinScreen/GridContainer/IpLineEdit.text = user_prefs.ip_address
	if port:
		$MarginContainer/JoinScreen/GridContainer/PortLineEdit.text = str(user_prefs.port)
		$MarginContainer/HostScreen/GridContainer/PortLineEdit.text = str(user_prefs.port)
	
	host_player_name_line_edit.text = user_prefs.host_name
	join_player_name_line_edit.text = user_prefs.peer_name
	

	multiplayer.peer_connected.connect(peer_connected)
	multiplayer.peer_disconnected.connect(peer_disconnected)
	multiplayer.connected_to_server.connect(connected_to_server)
	multiplayer.connection_failed.connect(connection_failed)


func peer_connected(id):
	print("Player Connected: " + str(id)) 

func peer_disconnected(id):
	print("Player disconnected: " + str(id))
	if id == 1:
		#reload current scene
		get_tree().change_scene_to_file("res://Scenes/ConnectionLost.tscn")
		#main_menu.hide()
		#settings_screen.show()
		GameManager.players.clear()
		connected_players = 0
	else:
		connected_players -= 1
		GameManager.players.erase(id)



func connected_to_server():
	print("Connected to server!")
	hobby_player_list.text = ""
	send_player_information.rpc_id(1, join_player_name_line_edit.text, multiplayer.get_unique_id(), color)

func connection_failed():
	print("Connection failed!")
	#reload current scene
	#get_tree().change_scene_to_file("res://Scenes/ConnectionLost.tscn")

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
		if connected_players == 4:
			peer.set_refuse_new_connections(true)
		hobby_label.text = "Connected Players (" + str(connected_players) + "/4) ..."
	if multiplayer.is_server():
		for i in GameManager.players:
			send_player_information.rpc(GameManager.players[i].name, i, GameManager.players[i].color)

@rpc("any_peer", "call_local")
func start_game():

	peer.set_refuse_new_connections(true)
	var scene = load("res://Scenes/Levels/test_scene_4.tscn").instantiate()
	get_node("../Level").add_child(scene)
	hide_menu.rpc()

@rpc("any_peer", "call_local")
func player_is_ready():
	ready_players += 1
	if ready_players == connected_players:
		start_game.rpc_id(1)

@rpc("any_peer", "call_local")
func hide_menu():
	self.hide()

func _on_host_game_button_pressed():
	main_menu.hide()
	host_screen.show()
	host_button.grab_focus()

func _on_host_button_pressed():

	peer = ENetMultiplayerPeer.new()

	#port = int(host_screen.get_node("GridContainer/PortLineEdit").text)
	port = 8910
	var error = peer.create_server(port, 6)
	
	if error != OK:
		print("cannot host: " + error)
		return
		
	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	
	multiplayer.set_multiplayer_peer(peer)

	upnp_setup()

	print("Waiting For Players")
	send_player_information(host_player_name_line_edit.text, multiplayer.get_unique_id(), color)

	lobby_screen.show()
	invite_code_label.text = "Invite Code: " + str(generated_invite_code)
	start_game_button.grab_focus()
	hobby_player_list.text = host_player_name_line_edit.text + "\n"
	host_screen.hide()

	if user_prefs:
		user_prefs.host_name = host_player_name_line_edit.text
		user_prefs.port = port
		user_prefs.save()

func _on_join_button_pressed():
	#address = $MarginContainer/JoinScreen/GridContainer/IpLineEdit.text
	#port = int($MarginContainer/JoinScreen/GridContainer/PortLineEdit.text)
	var join_code = $MarginContainer/JoinScreen/GridContainer/JoinCodeLineEdit.text

	var decoded = decode_invite_code(join_code)
	print("Decoded Invite Code: " + str(decoded))
	address = str(decoded[0]) + "." + str(decoded[1]) + "." + str(decoded[2]) + "." + str(decoded[3])
	port = 8910
	print("Decoded Address: " + address)
	#print("Decoded Port: " + str(port))

	peer = ENetMultiplayerPeer.new()
	peer.create_client(address, port)
	peer.get_host().compress(ENetConnection.COMPRESS_RANGE_CODER)
	
	multiplayer.set_multiplayer_peer(peer)
	lobby_screen.show()
	invite_code_label.hide()
	copy_button.hide()
	start_game_button.grab_focus()
	join_screen.hide()

	if user_prefs:
		user_prefs.peer_name = join_player_name_line_edit.text
		user_prefs.ip_address = address
		user_prefs.port = port
		user_prefs.save()

func _on_start_game_button_pressed():
	start_game_button.disabled = true
	player_is_ready.rpc_id(1)
	
	#start_game.rpc_id(1)

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

func _on_back_host_button_pressed():
	main_menu.show()
	host_screen.hide()

func _on_back_join_button_pressed():
	main_menu.show()
	join_screen.hide()

func _on_sfx_slider_value_changed(value:float):
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), linear_to_db(value))
	AudioServer.set_bus_mute(AudioServer.get_bus_index("SFX"), value < 0.05)

	if user_prefs:
		user_prefs.sfx_audio_level = value
		user_prefs.save()

func _on_music_slider_value_changed(value:float):
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(value))
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"), value < 0.05)

	if user_prefs:
		user_prefs.music_audio_level = value
		user_prefs.save()

func _on_audio_stream_player_2d_finished():
	$AudioStreamPlayer2D.play()


func upnp_setup():
	var upnp = UPNP.new()
	
	var discover_result = upnp.discover()
	assert(discover_result == UPNP.UPNP_RESULT_SUCCESS, \
		"UPNP Discover Failed! Error %s" % discover_result)

	assert(upnp.get_gateway() and upnp.get_gateway().is_valid_gateway(), \
		"UPNP Invalid Gateway!")

	var map_result = upnp.add_port_mapping(port)
	assert(map_result == UPNP.UPNP_RESULT_SUCCESS, \
		"UPNP Port Mapping Failed! Error %s" % map_result)
	
	print("Success! Join Address: %s" % upnp.query_external_address())
	generated_invite_code = transform_ip_into_invite_code(upnp.query_external_address())

func transform_ip_into_invite_code(ip):
	var ip_parts = ip.split(".")
	var invite_code = generate_invite_code(int(ip_parts[0]), int(ip_parts[1]), int(ip_parts[2]), int(ip_parts[3]))

	print("Invite Code: " + invite_code)

	#print("Decoded Invite Code: " + str(decode_invite_code(invite_code)))


	return invite_code


var BASE62_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
var BASE62_BASE = BASE62_ALPHABET.length()

# Helper function to encode a single number to a base62 string
func encode_number_to_base62(number: int) -> String:
	var encoded = ""
	while number > 0:
		var remainder = number % BASE62_BASE
		encoded = BASE62_ALPHABET[remainder] + encoded
		number = number / BASE62_BASE
	return encoded if encoded != "" else "0"

# Helper function to decode a base62 string back to a number
func decode_base62_to_number(encoded: String) -> int:
	var number = 0
	for charz in encoded:
		number = number * BASE62_BASE + BASE62_ALPHABET.find(charz)
	return number

# Function to generate invite code from four numbers
func generate_invite_code(num1: int, num2: int, num3: int, num4: int) -> String:
	var combined_number = (num1 << 24) | (num2 << 16) | (num3 << 8) | num4
	return encode_number_to_base62(combined_number)

# Function to decode invite code back to four numbers
func decode_invite_code(code: String) -> Array:
	var combined_number = decode_base62_to_number(code)
	var num1 = (combined_number >> 24) & 0xFF
	var num2 = (combined_number >> 16) & 0xFF
	var num3 = (combined_number >> 8) & 0xFF
	var num4 = combined_number & 0xFF
	return [num1, num2, num3, num4]

func _on_copy_button_pressed():
	DisplayServer.clipboard_set(generated_invite_code)
	copy_button.text = "  Copied!"
	copy_button.disabled = true