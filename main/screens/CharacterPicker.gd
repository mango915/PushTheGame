extends HBoxContainer

# Row of character portraits. Click one to play as it.
#
# Built in code from Characters.TEXTURES so adding a character is a one-line
# change there rather than more scene editing.

signal character_selected (index)

const SWATCH_SIZE := Vector2(56, 50)
const COLOR_SELECTED := Color(0.976, 0.949, 0.855)
const COLOR_UNSELECTED := Color(1, 1, 1, 0.45)

var _selected := 0
var _buttons := []

func _ready() -> void:
	add_theme_constant_override("separation", 8)
	alignment = BoxContainer.ALIGNMENT_CENTER
	_build()

func _build() -> void:
	for index in range(Characters.count()):
		var button := TextureButton.new()
		button.texture_normal = Characters.get_portrait(index)
		button.custom_minimum_size = SWATCH_SIZE
		button.ignore_texture_size = true
		button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		button.tooltip_text = Characters.character_name(index)
		button.pressed.connect(_on_pressed.bind(index))
		add_child(button)
		_buttons.append(button)
	_refresh()

func set_selected(index: int) -> void:
	_selected = Characters.clamp_index(index)
	_refresh()

func get_selected() -> int:
	return _selected

func _on_pressed(index: int) -> void:
	set_selected(index)
	emit_signal("character_selected", _selected)

func _refresh() -> void:
	# Dim the ones you are not playing as, so the choice reads at a glance
	# without needing a border or a checkmark.
	for i in range(_buttons.size()):
		_buttons[i].modulate = COLOR_SELECTED if i == _selected else COLOR_UNSELECTED
