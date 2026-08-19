extends "res://main/Screen.gd"

# `play_local` carries how many players are sitting down. Everything below the
# menu already supported four -- Game._do_game_setup spawns one player per entry
# in the roster and hands each the matching playerN_ input prefix, and every
# arena places PlayerStartPositions/Player1..4 -- but Main.start_game() built a
# roster of exactly two, so the third and fourth seats were unreachable.
signal play_local(player_count)
signal play_online

const MIN_LOCAL_PLAYERS := 2
const MAX_LOCAL_PLAYERS := 4

# Players 1 and 2 have keyboard bindings; 3 and 4 are gamepad-only. See [input]
# in project.godot, where playerN_* is bound to joypad device N-1.
const KEYBOARD_PLAYERS := 2

const COLOR_HINT := Color(0.435, 0.573, 0.643)
const COLOR_HINT_WARN := Color(0.851, 0.643, 0.255)

var local_player_count := MIN_LOCAL_PLAYERS

var _count_buttons := {}

@onready var _hint: Label = $Hint

func _ready() -> void:
	_build_player_count_row()
	# A pad plugged in while the menu is up should update the hint rather than
	# leaving a stale "not connected" warning on screen.
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_refresh_hint()

func _show_screen(_info: Dictionary = {}) -> void:
	# Re-check the pads every time the screen comes back up.
	_refresh_hint()

#####
# Player count
#####

func _build_player_count_row() -> void:
	var row := HBoxContainer.new()
	row.name = "LocalPlayerCount"
	row.anchor_left = 0.5
	row.anchor_right = 0.5
	row.offset_left = -150.0
	row.offset_right = 150.0
	row.offset_top = 248.0
	row.offset_bottom = 276.0
	row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	add_child(row)

	var label := Label.new()
	label.text = "LOCAL PLAYERS"
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", COLOR_HINT)
	row.add_child(label)

	# A ButtonGroup makes the row behave as one control: pressing a number
	# releases whichever was pressed before, so there is never a moment with two
	# counts selected or none.
	var group := ButtonGroup.new()
	for count in range(MIN_LOCAL_PLAYERS, MAX_LOCAL_PLAYERS + 1):
		var button := Button.new()
		button.text = str(count)
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(36, 28)
		button.add_theme_font_size_override("font_size", 18)
		button.button_pressed = (count == local_player_count)
		button.pressed.connect(_on_count_pressed.bind(count))
		row.add_child(button)
		_count_buttons[count] = button

func _on_count_pressed(count: int) -> void:
	local_player_count = clampi(count, MIN_LOCAL_PLAYERS, MAX_LOCAL_PLAYERS)
	_refresh_hint()

func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	_refresh_hint()

#####
# Hint
#####

# Spells out which input each seat uses, and says so plainly when a seat needs a
# pad that is not plugged in -- the alternative is a player pressing buttons on
# a controller the game was never going to read.
func _refresh_hint() -> void:
	if _hint == null:
		return

	var parts := PackedStringArray(["P1 WASD+C/V", "P2 Arrows+L/;"])
	var missing := false

	for seat in range(KEYBOARD_PLAYERS + 1, local_player_count + 1):
		var device := seat - 1
		if _is_pad_connected(device):
			parts.append("P%d pad %d" % [seat, device + 1])
		else:
			parts.append("P%d pad %d NOT CONNECTED" % [seat, device + 1])
			missing = true

	_hint.text = "  ·  ".join(parts) + "      ONLINE: host a room, share the code"
	_hint.add_theme_color_override(
		"font_color", COLOR_HINT_WARN if missing else COLOR_HINT)

func _is_pad_connected(device: int) -> bool:
	return device in Input.get_connected_joypads()

#####
# Buttons
#####

func _on_LocalButton_pressed() -> void:
	emit_signal("play_local", local_player_count)

func _on_OnlineButton_pressed() -> void:
	emit_signal("play_online")

func _on_CreditsButton_pressed() -> void:
	ui_layer.show_screen("CreditsScreen")

func _on_SettingsButton_pressed() -> void:
	ui_layer.show_screen("SettingsScreen")
