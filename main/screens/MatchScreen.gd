extends "res://main/Screen.gd"

@onready var matchmaker_player_count_control := $PanelContainer/VBoxContainer/MatchPanel/SpinBox
@onready var join_match_id_control := $PanelContainer/VBoxContainer/JoinPanel/LineEdit

@onready var lan_browser := $LanBrowser
@onready var lan_status_label := $LanBrowser/VBoxContainer/StatusLabel
@onready var lan_host_list := $LanBrowser/VBoxContainer/ScrollContainer/HostList
@onready var lan_refresh_button := $LanBrowser/VBoxContainer/Buttons/RefreshButton

@onready var steam_panel := $PanelContainer/VBoxContainer/SteamPanel
@onready var steam_status_label := $PanelContainer/VBoxContainer/SteamPanel/StatusLabel
@onready var steam_host_button := $PanelContainer/VBoxContainer/SteamPanel/SteamHostButton
@onready var steam_invite_button := $PanelContainer/VBoxContainer/SteamPanel/SteamInviteButton
@onready var steam_friends_button := $PanelContainer/VBoxContainer/SteamPanel/SteamFriendsButton

@onready var steam_browser := $SteamBrowser
@onready var steam_browser_status := $SteamBrowser/VBoxContainer/StatusLabel
@onready var steam_friend_list := $SteamBrowser/VBoxContainer/ScrollContainer/FriendList
@onready var steam_refresh_button := $SteamBrowser/VBoxContainer/Buttons/RefreshButton

func _ready() -> void:
	$PanelContainer/VBoxContainer/MatchPanel/MatchButton.pressed.connect(Callable(self, "_on_match_button_pressed").bind(OnlineMatch.MatchMode.MATCHMAKER))
	$PanelContainer/VBoxContainer/CreatePanel/CreateButton.pressed.connect(Callable(self, "_on_match_button_pressed").bind(OnlineMatch.MatchMode.CREATE))
	$PanelContainer/VBoxContainer/JoinPanel/JoinButton.pressed.connect(Callable(self, "_on_match_button_pressed").bind(OnlineMatch.MatchMode.JOIN))

	# The LAN buttons deliberately do NOT go through _on_match_button_pressed:
	# LAN play needs no Nakama session and no socket, so requiring one would
	# make the serverless mode depend on a server.
	$PanelContainer/VBoxContainer/LanPanel/LanHostButton.pressed.connect(Callable(self, "_on_LanHostButton_pressed"))
	$PanelContainer/VBoxContainer/LanPanel/LanFindButton.pressed.connect(Callable(self, "_on_LanFindButton_pressed"))
	lan_refresh_button.pressed.connect(Callable(self, "_on_LanRefreshButton_pressed"))
	$LanBrowser/VBoxContainer/Buttons/CloseButton.pressed.connect(Callable(self, "_on_LanCloseButton_pressed"))

	# Steam: same reasoning as LAN -- no Nakama session is involved, so these
	# never go through _on_match_button_pressed either.
	steam_host_button.pressed.connect(Callable(self, "_on_SteamHostButton_pressed"))
	steam_invite_button.pressed.connect(Callable(self, "_on_SteamInviteButton_pressed"))
	steam_friends_button.pressed.connect(Callable(self, "_on_SteamFriendsButton_pressed"))
	steam_refresh_button.pressed.connect(Callable(self, "_on_SteamRefreshButton_pressed"))
	$SteamBrowser/VBoxContainer/Buttons/CloseButton.pressed.connect(Callable(self, "_on_SteamCloseButton_pressed"))

	SteamMatch.steam_error.connect(Callable(self, "_on_SteamMatch_error"))
	SteamMatch.lobby_ready.connect(Callable(self, "_on_SteamMatch_lobby_ready"))
	SteamMatch.invite_received.connect(Callable(self, "_on_SteamMatch_invite_received"))

	OnlineMatch.match_joined.connect(Callable(self, "_on_OnlineMatch_joined"))

func _show_screen(_info: Dictionary = {}) -> void:
	matchmaker_player_count_control.value = 2
	join_match_id_control.text = ''
	_hide_lan_browser()
	_hide_steam_browser()
	_refresh_steam_panel()

func _hide_screen() -> void:
	_hide_lan_browser()
	_hide_steam_browser()

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

#####
# LAN play: no server, no room code, no IP address to type.
#####

var _lan_searching := false

func _on_LanHostButton_pressed() -> void:
	_hide_lan_browser()
	ui_layer.hide_message()
	# On failure OnlineMatch emits `error`, which Main turns into a message.
	OnlineMatch.host_lan_match()

func _on_LanFindButton_pressed() -> void:
	ui_layer.hide_message()
	lan_browser.visible = true
	_search_lan()

func _on_LanRefreshButton_pressed() -> void:
	_search_lan()

func _on_LanCloseButton_pressed() -> void:
	_hide_lan_browser()

func _hide_lan_browser() -> void:
	# _show_screen runs before _ready has resolved the @onready vars the first
	# time the screen is displayed.
	if lan_browser == null:
		return
	lan_browser.visible = false
	_clear_lan_host_list()

func _clear_lan_host_list() -> void:
	for child in lan_host_list.get_children():
		lan_host_list.remove_child(child)
		child.queue_free()

func _search_lan() -> void:
	if _lan_searching:
		return
	_lan_searching = true

	_clear_lan_host_list()
	lan_refresh_button.disabled = true
	lan_status_label.text = "Looking for games..."

	var hosts: Array = await LanMatch.discover_hosts()

	_lan_searching = false
	lan_refresh_button.disabled = false

	# The player may have left the screen (or started a game) while we searched.
	if not lan_browser.visible:
		return

	_clear_lan_host_list()
	if hosts.size() == 0:
		lan_status_label.text = "No games found. Make sure the host is on the same wi-fi."
		return

	lan_status_label.text = "Pick a game to join:"
	for host in hosts:
		var button := Button.new()
		button.text = "%s   (%d/%d)" % [host.name, host.players, host.max_players]
		button.disabled = not host.open
		button.pressed.connect(Callable(self, "_on_lan_host_chosen").bind(host))
		lan_host_list.add_child(button)

func _on_lan_host_chosen(host: Dictionary) -> void:
	_hide_lan_browser()
	ui_layer.show_message("Joining %s..." % host.name)
	# The address came from the discovery reply, so nobody had to type it.
	OnlineMatch.join_lan_match(host.address, host.port)

# Named matches are create-or-join, so a generated code that happens to collide
# with a live match drops the would-be host into a stranger's game instead of
# hosting. Detect that (we asked to host but are not peer 1) and retry with a
# fresh code.
const MAX_HOST_ATTEMPTS := 5
var _host_attempts := 0

func _on_OnlineMatch_joined(match_id: String, match_mode: int):
	_hide_lan_browser()
	ui_layer.hide_message()

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

	if match_mode != OnlineMatch.MatchMode.MATCHMAKER and not OnlineMatch.is_steam():
		# Show the room code, not the underlying match UUID. Steam has neither:
		# people get in by invite, so there is nothing to read out.
		info['match_id'] = OnlineMatch.room_code if OnlineMatch.room_code != '' else match_id

	ui_layer.show_screen("ReadyScreen", info)

func _on_PasteButton_pressed() -> void:
	join_match_id_control.text = DisplayServer.clipboard_get( )

func _on_LeaderboardButton_pressed() -> void:
	ui_layer.show_screen("LeaderboardScreen")

#####
# Steam play: friends and invites, through Steam's own networking.
#
# The whole section is inert -- visible but disabled, with the reason on the
# label -- when the GodotSteam extension is not installed, which is the state
# this project ships in. See docs/steam.md.
#####

func _refresh_steam_panel() -> void:
	# _show_screen runs before _ready has resolved the @onready vars the first
	# time the screen is displayed.
	if steam_status_label == null:
		return

	var available: bool = SteamMatch.is_available()
	steam_status_label.text = SteamMatch.status_text()

	steam_host_button.disabled = not available
	steam_friends_button.disabled = not available
	# Inviting needs a lobby to invite people into.
	steam_invite_button.disabled = not available or SteamMatch.current_lobby == 0

	var reason := "" if available else SteamMatch.UNAVAILABLE_MESSAGE
	steam_host_button.tooltip_text = reason
	steam_invite_button.tooltip_text = reason
	steam_friends_button.tooltip_text = reason

func _on_SteamHostButton_pressed() -> void:
	_hide_lan_browser()
	_hide_steam_browser()
	ui_layer.hide_message()
	# Friends-only lobbies: this mode is for playing with people you know, and
	# a public lobby would list the game to strangers.
	if OnlineMatch.host_steam_match(true):
		ui_layer.show_message("Opening a Steam lobby...")
	_refresh_steam_panel()

func _on_SteamInviteButton_pressed() -> void:
	# Steam's own overlay is what players expect, and it handles the whole
	# picker for us. It only draws when the game runs under the Steam client.
	if not SteamMatch.open_invite_overlay():
		ui_layer.show_message(SteamMatch.last_error)

func _on_SteamFriendsButton_pressed() -> void:
	ui_layer.hide_message()
	steam_browser.visible = true
	_refresh_steam_friends()

func _on_SteamRefreshButton_pressed() -> void:
	_refresh_steam_friends()

func _on_SteamCloseButton_pressed() -> void:
	_hide_steam_browser()

func _hide_steam_browser() -> void:
	if steam_browser == null:
		return
	steam_browser.visible = false
	_clear_steam_friend_list()

func _clear_steam_friend_list() -> void:
	for child in steam_friend_list.get_children():
		steam_friend_list.remove_child(child)
		child.queue_free()

func _refresh_steam_friends() -> void:
	_clear_steam_friend_list()

	if not SteamMatch.is_available():
		steam_browser_status.text = SteamMatch.UNAVAILABLE_MESSAGE
		return

	var friends: Array = SteamMatch.refresh_friends(true)
	if friends.size() == 0:
		steam_browser_status.text = "No friends online right now."
		return

	if SteamMatch.current_lobby == 0:
		steam_browser_status.text = "Host on Steam first, then invite:"
	else:
		steam_browser_status.text = "Pick a friend to invite:"

	for friend in friends:
		var button := Button.new()
		button.text = "%s   INVITE" % friend.name
		# Nobody can be invited before there is a lobby to invite them to.
		button.disabled = SteamMatch.current_lobby == 0
		button.pressed.connect(Callable(self, "_on_steam_friend_chosen").bind(friend))
		steam_friend_list.add_child(button)

func _on_steam_friend_chosen(friend: Dictionary) -> void:
	if SteamMatch.invite_friend(int(friend.steam_id)):
		steam_browser_status.text = "Invited %s." % friend.name
	else:
		steam_browser_status.text = SteamMatch.last_error

func _on_SteamMatch_error(message: String) -> void:
	_refresh_steam_panel()
	if steam_browser != null and steam_browser.visible:
		steam_browser_status.text = message

func _on_SteamMatch_lobby_ready(_lobby_id: int) -> void:
	_refresh_steam_panel()
	if steam_browser != null and steam_browser.visible:
		_refresh_steam_friends()

func _on_SteamMatch_invite_received(_lobby_id: int, _friend_steam_id: int, friend_name: String) -> void:
	# Accepting happens in Steam's own notification; this is only so the player
	# is not surprised when the game suddenly joins a match.
	var who := friend_name if friend_name != "" else "A friend"
	ui_layer.show_message("%s invited you to play - accept it in Steam" % who)
