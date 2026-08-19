extends HBoxContainer

@onready var name_label := $NameLabel
@onready var status_label := $StatusLabel
@onready var score_label := $ScoreLabel

var status := "": set = set_status
var score := 0: set = set_score

# Portrait shown to the left of the name, so you can see who is playing what.
const PORTRAIT_SIZE := Vector2(34, 30)

var character := 0
var _portrait: TextureRect

func initialize(_name: String, _status: String = "Connected.", _score: int = 0, _character: int = 0) -> void:
	name_label.text = _name
	self.status = _status
	self.score = _score
	set_character(_character)

func set_character(index: int) -> void:
	character = Characters.clamp_index(index)

	if _portrait == null:
		_portrait = TextureRect.new()
		_portrait.custom_minimum_size = PORTRAIT_SIZE
		_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		add_child(_portrait)
		# Sits before the score and name columns.
		move_child(_portrait, 0)

	_portrait.texture = Characters.get_portrait(character)

func set_player_name(_name: String) -> void:
	name_label.text = _name

func set_status(_status: String) -> void:
	status = _status
	status_label.text = status

func set_score(_score: int):
	score = _score
	if score == 0:
		score_label.text = ""
	else:
		score_label.text = str(score)
