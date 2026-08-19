extends "res://main/Screen.gd"

var PeerStatus = preload("res://main/screens/PeerStatus.tscn");

@onready var ready_button := $Panel/ReadyButton
@onready var match_id_container := $Panel/MatchIDContainer
@onready var match_id_label := $Panel/MatchIDContainer/MatchID
@onready var status_container := $Panel/StatusContainer

signal ready_pressed ()

const CharacterPickerScript = preload("res://main/screens/CharacterPicker.gd")

var character_picker

func _ready() -> void:
	clear_players()
	_build_character_picker()

	OnlineMatch.player_joined.connect(Callable(self, "_on_OnlineMatch_player_joined"))
	OnlineMatch.player_left.connect(Callable(self, "_on_OnlineMatch_player_left"))
	OnlineMatch.match_ready.connect(Callable(self, "_on_OnlineMatch_match_ready"))
	OnlineMatch.match_not_ready.connect(Callable(self, "_on_OnlineMatch_match_not_ready"))
	OnlineMatch.player_updated.connect(Callable(self, "_on_OnlineMatch_player_updated"))

# Lets a player pick their character while waiting in the lobby. Announced to
# the other peers straight away so everyone's list stays in step.
func _build_character_picker() -> void:
	character_picker = HBoxContainer.new()
	character_picker.set_script(CharacterPickerScript)
	character_picker.name = "CharacterPicker"
	$Panel.add_child(character_picker)
	character_picker.set_anchors_preset(Control.PRESET_CENTER_TOP)
	character_picker.position = Vector2(0, 4)
	character_picker.character_selected.connect(Callable(self, "_on_character_selected"))
	character_picker.set_selected(Online.character_index)

func _on_character_selected(index: int) -> void:
	Online.set_character(index)
	OnlineMatch.announce_local_character()

	# Reflect it immediately on our own row rather than waiting for the echo.
	var my_peer_id := get_tree().get_multiplayer().get_unique_id()
	set_character(my_peer_id, index)

func set_character(peer_id: int, index: int) -> void:
	var status_node = status_container.get_node_or_null(str(peer_id))
	if status_node and status_node.has_method("set_character"):
		status_node.set_character(index)

func _on_OnlineMatch_player_updated(player) -> void:
	set_character(player.peer_id, player.character)
	var status_node = status_container.get_node_or_null(str(player.peer_id))
	if status_node and status_node.has_method("set_player_name"):
		status_node.set_player_name(player.username)

func _show_screen(info: Dictionary = {}) -> void:
	if character_picker:
		character_picker.set_selected(Online.character_index)
	var players: Dictionary = info.get("players", {})
	var match_id: String = info.get("match_id", '')
	var clear: bool = info.get("clear", false)

	if players.size() > 0 or clear:
		clear_players()

	for peer_id in players:
		var entry = players[peer_id]
		add_player(peer_id, entry['username'], int(entry.get('character', 0)))

	if match_id:
		match_id_container.visible = true
		match_id_label.text = match_id
	else:
		match_id_container.visible = false

	ready_button.grab_focus()

func clear_players() -> void:
	for child in status_container.get_children():
		status_container.remove_child(child)
		child.queue_free()
	ready_button.disabled = true

func hide_match_id() -> void:
	match_id_container.visible = false

func add_player(peer_id: int, username: String, character: int = 0) -> void:
	if not status_container.has_node(str(peer_id)):
		var status = PeerStatus.instantiate()
		status_container.add_child(status)
		status.initialize(username, "Connected.", 0, character)
		status.name = str(peer_id)

func remove_player(peer_id: int) -> void:
	var status = status_container.get_node(str(peer_id))
	if status:
		status.queue_free()

func set_status(peer_id: int, status: String) -> void:
	var status_node = status_container.get_node(str(peer_id))
	if status_node:
		status_node.set_status(status)

func get_status(peer_id: int) -> String:
	var status_node = status_container.get_node(str(peer_id))
	if status_node:
		return status_node.status
	return ''

func reset_status(status: String) -> void:
	for child in status_container.get_children():
		child.set_status(status)

func set_score(peer_id: int, score: int) -> void:
	var status_node = status_container.get_node(str(peer_id))
	if status_node:
		status_node.set_score(score)

func set_ready_button_enabled(enabled: bool = true) -> void:
	ready_button.disabled = !enabled
	if enabled:
		ready_button.grab_focus()

func _on_ReadyButton_pressed() -> void:
	emit_signal("ready_pressed")

func _on_MatchCopyButton_pressed() -> void:
	DisplayServer.clipboard_set(match_id_label.text)

#####
# OnlineMatch callbacks:
#####

func _on_OnlineMatch_player_joined(player) -> void:
	add_player(player.peer_id, player.username, player.character)

func _on_OnlineMatch_player_left(player) -> void:
	remove_player(player.peer_id)

func _on_OnlineMatch_match_ready(_players: Dictionary) -> void:
	set_ready_button_enabled(true)

func _on_OnlineMatch_match_not_ready() -> void:
	set_ready_button_enabled(false)
