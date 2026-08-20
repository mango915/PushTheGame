extends "res://main/Screen.gd"

# In-game settings. Lets a player retune movement feel, match rules, their
# display name and which Nakama server to use, without opening the editor.
#
# The UI is built in code rather than authored as a .tscn on purpose: the rows
# are uniform and driven by the ROWS table below, so adding a new tunable is one
# line here instead of hand-editing scene text.
#
# Gameplay values are the HOST's in an online match -- Game.gd ships them to
# every peer at match start, because peers running different physics numbers
# desync silently. The screen says so, so a client is not confused when their
# own numbers appear not to apply.

const LABEL_WIDTH := 190
const VALUE_WIDTH := 70

const COLOR_BACKGROUND := Color(0.055, 0.098, 0.161)
const COLOR_HEADING := Color(0.976, 0.949, 0.855)
const COLOR_HINT := Color(0.514, 0.706, 0.784)

# field, label, minimum, maximum, step
const ROWS := [
	["speed", "Run speed", 50.0, 900.0, 10.0],
	["jump_speed", "Jump strength", 200.0, 1500.0, 10.0],
	["gravity", "Gravity (0 = default)", 0.0, 5000.0, 25.0],
	["acceleration", "Acceleration", 200.0, 6000.0, 50.0],
	["friction", "Friction", 100.0, 5000.0, 50.0],
	["terminal_velocity", "Max fall speed", 200.0, 3000.0, 50.0],
	["push_back_speed", "Hit knockback", 0.0, 600.0, 5.0],
	["throw_velocity", "Throw strength", 0.0, 1200.0, 10.0],
	["rounds_to_win", "Rounds to win match", 1.0, 20.0, 1.0],
]

var _settings: GameSettings
var _sliders := {}
var _value_labels := {}
var _name_field: LineEdit
var _host_field: LineEdit
var _port_field: LineEdit
var _jump_readout: Label

# action -> Array[Button], one per key slot.
var _bind_buttons := {}
# The slot currently waiting for a keypress: {"action": String, "slot": int}.
var _capturing := {}
var _bind_hint: Label

func _ready() -> void:
	_settings = GameSettings.load_saved()
	_build_ui()
	_refresh_from_settings()

func _show_screen(_info: Dictionary = {}) -> void:
	# Re-read on every entry: another screen (or a host) may have changed things.
	_settings = GameSettings.load_saved()
	_refresh_from_settings()
	_capturing = {}
	_reset_bind_hint()
	_refresh_all_binds()

func _hide_screen() -> void:
	# An armed slot left behind would eat the first keypress on whatever screen
	# comes next.
	_capturing = {}

#####
# UI construction
#####

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.color = COLOR_BACKGROUND
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 58)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 60)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	scroll.add_child(column)

	column.add_child(_heading("SETTINGS"))

	# --- Player ---
	column.add_child(_heading("Player"))
	_name_field = LineEdit.new()
	_name_field.placeholder_text = "Display name"
	column.add_child(_labelled_row("Name", _name_field))

	# --- Controls ---
	column.add_child(_heading("Controls"))
	_bind_hint = _hint("")
	_reset_bind_hint()
	column.add_child(_bind_hint)
	for action in Keybinds.rebindable_actions():
		column.add_child(_bind_row(action))

	# --- Gameplay ---
	column.add_child(_heading("Gameplay"))
	var note := _hint("In an online match the host's values are used by everyone.")
	column.add_child(note)

	for row in ROWS:
		column.add_child(_slider_row(row))

	# Jump strength and gravity are not independent -- this shows what the
	# combination actually produces, which is what a player is really tuning.
	_jump_readout = _hint("")
	column.add_child(_jump_readout)

	# --- Server ---
	column.add_child(_heading("Server"))
	_host_field = LineEdit.new()
	_host_field.placeholder_text = "127.0.0.1"
	column.add_child(_labelled_row("Nakama host", _host_field))
	_port_field = LineEdit.new()
	_port_field.placeholder_text = "7350"
	column.add_child(_labelled_row("Port", _port_field))
	column.add_child(_hint("Changing the server signs you out of the current one."))

	# --- Buttons ---
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 20)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER

	var save_button := Button.new()
	save_button.text = "Save"
	save_button.pressed.connect(_on_save_pressed)
	buttons.add_child(save_button)

	var reset_button := Button.new()
	reset_button.text = "Reset to defaults"
	reset_button.pressed.connect(_on_reset_pressed)
	buttons.add_child(reset_button)

	column.add_child(buttons)

func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", COLOR_HEADING)
	return label

func _hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", COLOR_HINT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func _labelled_row(text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = LABEL_WIDTH
	row.add_child(label)

	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row

func _slider_row(row: Array) -> HBoxContainer:
	var field: String = row[0]

	var slider := HSlider.new()
	slider.min_value = row[2]
	slider.max_value = row[3]
	slider.step = row[4]
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.y = 18

	var value_label := Label.new()
	value_label.custom_minimum_size.x = VALUE_WIDTH
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	slider.value_changed.connect(_on_slider_changed.bind(field))

	_sliders[field] = slider
	_value_labels[field] = value_label

	var container := HBoxContainer.new()
	container.add_theme_constant_override("separation", 10)

	var label := Label.new()
	label.text = row[1]
	label.custom_minimum_size.x = LABEL_WIDTH
	container.add_child(label)
	container.add_child(slider)
	container.add_child(value_label)
	return container

#####
# Key binding
#####

func _seat_of(action: String) -> String:
	for prefix in Keybinds.PREFIXES:
		if action.begins_with(prefix):
			return prefix.substr(6, 1)
	return "?"

func _bind_row(action: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var label := Label.new()
	label.text = "P%s  %s" % [_seat_of(action), Keybinds.label_for(action)]
	label.custom_minimum_size.x = LABEL_WIDTH
	row.add_child(label)

	var buttons := []
	for slot in range(Keybinds.SLOTS):
		var button := Button.new()
		button.custom_minimum_size.x = 90
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Left click rebinds, right click clears. A dedicated clear button per
		# slot would double the width of a list that is already 14 rows long.
		button.pressed.connect(_on_bind_pressed.bind(action, slot))
		button.gui_input.connect(_on_bind_gui_input.bind(action, slot))
		row.add_child(button)
		buttons.append(button)

	_bind_buttons[action] = buttons
	_refresh_bind_row(action)
	return row

func _refresh_bind_row(action: String) -> void:
	if not _bind_buttons.has(action):
		return
	var keys: Array = Keybinds.keys_for(action)
	for slot in range(_bind_buttons[action].size()):
		var button: Button = _bind_buttons[action][slot]
		if _capturing.get("action", "") == action \
				and _capturing.get("slot", -1) == slot:
			button.text = "press a key"
		else:
			button.text = Keybinds.key_name(keys[slot])

func _refresh_all_binds() -> void:
	for action in _bind_buttons:
		_refresh_bind_row(action)

func _reset_bind_hint() -> void:
	if _bind_hint:
		_bind_hint.text = ("Click a key to rebind, right-click to clear. "
			+ "Escape cancels. Players 3 and 4 are gamepad-only.")

func _on_bind_pressed(action: String, slot: int) -> void:
	_capturing = {"action": action, "slot": slot}
	_bind_hint.text = "Press a key for P%s %s, or Escape to cancel." % [
		_seat_of(action), Keybinds.label_for(action)]
	_refresh_all_binds()

func _on_bind_gui_input(event: InputEvent, action: String, slot: int) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		Keybinds.clear_key(action, slot)
		_refresh_all_binds()

# Captured here rather than in _unhandled_input: a Button has focus while it is
# waiting, and would otherwise swallow Space and Enter as "press me again" --
# which are exactly two keys somebody will try to bind to jump.
func _input(event: InputEvent) -> void:
	if _capturing.is_empty() or not visible:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	get_viewport().set_input_as_handled()

	var code: int = event.physical_keycode
	if code == 0:
		code = event.keycode
	var action: String = _capturing["action"]
	var slot: int = _capturing["slot"]
	_capturing = {}

	if code == KEY_ESCAPE:
		_reset_bind_hint()
		_refresh_all_binds()
		return

	var taken := Keybinds.set_key(action, slot, code)
	if taken == "reserved":
		_bind_hint.text = "%s is reserved for the pause menu." % Keybinds.key_name(code)
	elif taken != "":
		# Say what was taken and from whom. The alternative -- silently leaving
		# one key firing two actions -- reads as the game being broken.
		_bind_hint.text = "%s was bound to P%s %s; that binding was cleared." % [
			Keybinds.key_name(code), _seat_of(taken), Keybinds.label_for(taken)]
	else:
		_reset_bind_hint()
	_refresh_all_binds()

#####
# Values
#####

func _refresh_from_settings() -> void:
	if _name_field == null:
		return

	_name_field.text = Online.display_name
	_host_field.text = Online.nakama_host
	_port_field.text = str(Online.nakama_port)

	for field in _sliders:
		var slider: HSlider = _sliders[field]
		# set_value_no_signal, or each refresh would write back through
		# _on_slider_changed and clamp values to the slider's range.
		slider.set_value_no_signal(float(_settings.get(field)))
		_update_value_label(field)

	_update_jump_readout()

func _on_slider_changed(value: float, field: String) -> void:
	if field == "rounds_to_win" or field == "sync_delay":
		_settings.set(field, int(value))
	else:
		_settings.set(field, value)

	# gravity feeds get_gravity(), which caches the project default.
	if field == "gravity":
		_settings.apply_dict({"gravity": value})

	_update_value_label(field)
	_update_jump_readout()

func _update_value_label(field: String) -> void:
	var value = _settings.get(field)
	if field == "rounds_to_win" or field == "sync_delay":
		_value_labels[field].text = str(int(value))
	elif field == "gravity" and float(value) <= 0.0:
		_value_labels[field].text = "auto"
	else:
		_value_labels[field].text = "%d" % int(round(float(value)))

func _update_jump_readout() -> void:
	if _jump_readout == null:
		return
	var height := _settings.get_jump_height()
	var airtime := _settings.get_jump_airtime()
	var distance := _settings.get_jump_distance()
	_jump_readout.text = (
		"A running jump reaches %d px high, hangs for %.2fs, and covers %d px.\n"
		+ "Jump length comes from all three: jump strength and gravity set the "
		+ "airtime, run speed sets how far you travel during it."
	) % [int(round(height)), airtime, int(round(distance))]

#####
# Buttons
#####

func _on_save_pressed() -> void:
	_settings.save_to_config()
	Keybinds.save()

	Online.set_display_name(_name_field.text)

	var host := _host_field.text.strip_edges()
	var port := int(_port_field.text.strip_edges())
	if port <= 0:
		port = 7350
	if host != "" and (host != Online.nakama_host or port != Online.nakama_port):
		Online.apply_server_settings(host, port, Online.nakama_scheme)
	else:
		Online.save_settings()

	# Take effect on the next round without a restart.
	var game := get_tree().get_root().find_child("Game", true, false)
	if game and game.has_method("reload_game_settings"):
		game.reload_game_settings()

	ui_layer.show_message("Settings saved")

func _on_reset_pressed() -> void:
	GameSettings.clear_saved()
	_settings = GameSettings.load_saved()
	Keybinds.clear_saved()
	Keybinds.reset_to_defaults()
	_capturing = {}
	_reset_bind_hint()
	_refresh_all_binds()
	_refresh_from_settings()
	ui_layer.show_message("Settings reset to defaults")
