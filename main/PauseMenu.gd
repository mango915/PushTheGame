extends Control

# The in-match pause menu.
#
# Before this, the only in-match control was the Back button, which tears the
# whole match down -- there was no way to stop for a moment, and no deliberate
# way to leave that did not feel like an accident.
#
# WHY THIS OWNS ITS OWN INPUT
#
# This node runs with PROCESS_MODE_ALWAYS, and it has to: a paused SceneTree
# stops _input/_unhandled_input on every node that inherits the default process
# mode, Main included. If Main handled the pause key, pausing would work and
# UNpausing would be unreachable -- the input that closes the menu would never
# be delivered. So the toggle lives here, and Main only says when pausing is
# allowed (`enabled`) and reacts to `quit_to_menu`. Signals are direct calls, so
# Main's handler still runs while the tree is paused.
#
# WHY ONLINE DOES NOT ACTUALLY PAUSE
#
# There is no such thing as pausing a multiplayer match: the other peers keep
# playing regardless. Worse, pausing locally would stop this peer simulating
# while remote players keep sending input to replay, so it would come back
# desynced with no error anywhere (see the sync notes in actors/Player.gd). So
# online play gets the menu WITHOUT the pause, and the menu says so.

signal quit_to_menu ()
signal opened ()
signal closed ()

const COLOR_SCRIM := Color(0.055, 0.098, 0.161, 0.78)
const COLOR_HEADING := Color(0.976, 0.949, 0.855)
const COLOR_HINT := Color(0.514, 0.706, 0.784)

# Set by Main: pausing is only meaningful while a round is actually running.
var enabled := false

# True when WE paused the tree, so closing does not unpause a tree that
# something else (the round countdown, a setup handshake) is holding.
var _paused_tree := false

var _hint: Label
var _resume_button: Button

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_fill_parent(self)
	visible = false
	_build()

# Anchors and offsets written out rather than set_anchors_preset(), which left
# this node 0x0 -- and a zero-sized Control does not clip its children, so the
# menu still drew, stacked in the corner, with the scrim collapsed to nothing.
# The HUD sizes itself the same explicit way and has always laid out correctly.
static func _fill_parent(control: Control) -> void:
	control.anchor_left = 0.0
	control.anchor_top = 0.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0

func _build() -> void:
	var scrim := ColorRect.new()
	_fill_parent(scrim)
	scrim.color = COLOR_SCRIM
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)

	# Filling the parent and centring the CONTENT, rather than sizing the column
	# to its contents and trying to centre the column: a container's own size is
	# only known after its children are in it, so anchoring it to the middle
	# beforehand centres a box that is still empty.
	var column := VBoxContainer.new()
	_fill_parent(column)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 10)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)

	var heading := Label.new()
	heading.text = "PAUSED"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 34)
	heading.add_theme_color_override("font_color", COLOR_HEADING)
	heading.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(heading)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", COLOR_HINT)
	_hint.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(_hint)

	_resume_button = Button.new()
	_resume_button.text = "Resume"
	_resume_button.custom_minimum_size = Vector2(150, 30)
	_resume_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_resume_button.pressed.connect(close)
	column.add_child(_resume_button)

	var quit_button := Button.new()
	quit_button.text = "Quit to menu"
	quit_button.custom_minimum_size = Vector2(150, 30)
	quit_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	quit_button.pressed.connect(_on_quit_pressed)
	column.add_child(quit_button)

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("pause"):
		return
	if not enabled and not visible:
		return
	get_viewport().set_input_as_handled()
	toggle()

func toggle() -> void:
	if visible:
		close()
	else:
		open()

func open() -> void:
	if visible:
		return
	visible = true

	if GameState.online_play:
		_hint.text = "The match keeps running - you cannot pause other players."
	else:
		_hint.text = "Nobody moves until you say so."
		# Only ever pause a tree that is actually running: the round countdown
		# holds it paused too, and unpausing on close would start the round
		# early.
		if not get_tree().paused:
			get_tree().paused = true
			_paused_tree = true

	_resume_button.grab_focus()
	emit_signal("opened")

func close() -> void:
	if not visible:
		return
	visible = false

	if _paused_tree:
		get_tree().paused = false
		_paused_tree = false

	emit_signal("closed")

func _on_quit_pressed() -> void:
	# Unpause before handing back, or the menu we return to is frozen too.
	close()
	emit_signal("quit_to_menu")
