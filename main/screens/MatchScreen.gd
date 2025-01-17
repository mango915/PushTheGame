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
	# If our session has expired, show the ConnectionScreen again.
	if Online.nakama_session == null or Online.nakama_session.is_expired():
		ui_layer.show_screen("ConnectionScreen", { reconnect = true, next_screen = null })

		# Wait to see if we get a new valid session.
		await Online.session_changed
		if Online.nakama_session == null:
			return

	# Connect socket to realtime Nakama API if not connected.
	if not Online.is_nakama_socket_connected():
		Online.connect_nakama_socket()
		await Online.socket_connected

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
	OnlineMatch.create_match(Online.nakama_socket)

func _join_match() -> void:
	var match_id = join_match_id_control.text.strip_edges()
	if match_id == '':
		ui_layer.show_message("Need to paste Match ID to join")
		return
	if not match_id.ends_with('.'):
		match_id += '.'

	OnlineMatch.join_match(Online.nakama_socket, match_id)

func _on_OnlineMatch_joined(match_id: String, match_mode: int):
	var info = {
		players = OnlineMatch.players,
		clear = true,
	}

	if match_mode != OnlineMatch.MatchMode.MATCHMAKER:
		info['match_id'] = match_id

	ui_layer.show_screen("ReadyScreen", info)

func _on_PasteButton_pressed() -> void:
	join_match_id_control.text = DisplayServer.clipboard_get( )

func _on_LeaderboardButton_pressed() -> void:
	ui_layer.show_screen("LeaderboardScreen")
