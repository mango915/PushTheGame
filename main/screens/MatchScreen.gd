extends "res://main/Screen.gd"

@onready var matchmaker_player_count_control := $PanelContainer/VBoxContainer/MatchPanel/SpinBox
@onready var join_match_id_control := $PanelContainer/VBoxContainer/JoinPanel/LineEdit

func _ready() -> void:
	$PanelContainer/VBoxContainer/MatchPanel/MatchButton.pressed.connect(Callable(self, "_on_match_button_pressed").bind(OnlineMatch.MatchMode.MATCHMAKER))
	$PanelContainer/VBoxContainer/CreatePanel/CreateButton.pressed.connect(Callable(self, "_on_match_button_pressed").bind(OnlineMatch.MatchMode.CREATE))
	$PanelContainer/VBoxContainer/JoinPanel/JoinButton.pressed.connect(Callable(self, "_on_match_button_pressed").bind(OnlineMatch.MatchMode.JOIN))

	OnlineMatch.match_joined.connect(Callable(self, "_on_OnlineMatch_joined"))

func _show_screen(_info: Dictionary = {}) -> void:
	matchmaker_player_count_control.value = 2
	join_match_id_control.text = ''

func _on_match_button_pressed(mode) -> void:
	# Re-authenticate silently if the session lapsed, rather than bouncing the
	# player back to a login screen.
	if not Online.has_valid_session():
		ui_layer.show_message("Signing in...")
		if not await Online.ensure_session():
			ui_layer.show_message("Could not sign in")
			return
		ui_layer.hide_message()

	# Connect socket to realtime Nakama API if not connected.
	if not Online.is_nakama_socket_connected():
		ui_layer.show_message("Connecting...")
		if not await Online.connect_nakama_socket():
			ui_layer.show_message("Could not reach the server")
			return

	ui_layer.hide_message()

	# Call internal method to do actual work.
	match mode:
		OnlineMatch.MatchMode.MATCHMAKER:
			_start_matchmaking()
		OnlineMatch.MatchMode.CREATE:
			_create_match()
		OnlineMatch.MatchMode.JOIN:
			_join_match()

func _start_matchmaking() -> void:
	var min_players = matchmaker_player_count_control.value

	ui_layer.hide_screen()
	ui_layer.show_message("Looking for match...")

	var data = {
		min_count = min_players,
		string_properties = {
			game = "push_the_game",
			engine = "godot",
		},
		query = "+properties.game:push_the_game +properties.engine:godot",
	}
	OnlineMatch.start_matchmaking(Online.nakama_socket, data)

func _create_match() -> void:
	# Hosts under a short generated room code rather than a raw match UUID, so
	# the host has something they can read out to a friend.
	_host_attempts = 0
	OnlineMatch.host_room(Online.nakama_socket)

func _join_match() -> void:
	var code = join_match_id_control.text.strip_edges()
	if code == '':
		ui_layer.show_message("Enter a room code to join")
		return

	OnlineMatch.join_room(Online.nakama_socket, code)

# Named matches are create-or-join, so a generated code that happens to collide
# with a live match drops the would-be host into a stranger's game instead of
# hosting. Detect that (we asked to host but are not peer 1) and retry with a
# fresh code.
const MAX_HOST_ATTEMPTS := 5
var _host_attempts := 0

func _on_OnlineMatch_joined(match_id: String, match_mode: int):
	if match_mode == OnlineMatch.MatchMode.CREATE:
		var my_peer_id = get_tree().get_multiplayer().get_unique_id()
		if my_peer_id != 1:
			_host_attempts += 1
			if _host_attempts < MAX_HOST_ATTEMPTS:
				OnlineMatch.leave()
				OnlineMatch.host_room(Online.nakama_socket)
				return
			ui_layer.show_message("Could not find a free room code")
			OnlineMatch.leave()
			return

	var info = {
		players = OnlineMatch.players,
		clear = true,
	}

	if match_mode != OnlineMatch.MatchMode.MATCHMAKER:
		# Show the room code, not the underlying match UUID.
		info['match_id'] = OnlineMatch.room_code if OnlineMatch.room_code != '' else match_id

	ui_layer.show_screen("ReadyScreen", info)

func _on_PasteButton_pressed() -> void:
	join_match_id_control.text = DisplayServer.clipboard_get( )

func _on_LeaderboardButton_pressed() -> void:
	ui_layer.show_screen("LeaderboardScreen")
