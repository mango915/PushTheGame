extends Control

# The in-match scoreboard: one chip per player, along the bottom of the screen.
#
# Everything the game already tracked -- who is in the round, which character
# they picked, how many rounds they have won, and whether they are still alive
# this round -- was only ever visible BETWEEN rounds, on ReadyScreen in online
# play and not at all in local play. In a four-player match that leaves nobody
# able to tell which whale is theirs or who is about to win.
#
# Built in code rather than authored as a .tscn, matching
# main/screens/SettingsScreen.gd: the chips are uniform and generated from the
# roster, so there is no layout worth hand-editing.
#
# UILayer owns the instance (see UILayer._ready) and Main drives it. It lives
# under UILayer/Overlay, so it deliberately sits outside the Screens stack and
# is not touched by show_screen()/hide_screen()/hide_all() -- Main shows and
# hides it around the round instead.

const PORTRAIT_HEIGHT := 22.0
# Characters.FRAME_SIZE is 76x66; keep the portrait's aspect so the whales are
# not squashed.
const PORTRAIT_ASPECT := 76.0 / 66.0

const COLOR_NAME := Color(1, 1, 1, 0.92)
const COLOR_SCORE := Color(0.976, 0.949, 0.855)
const COLOR_OUTLINE := Color(0, 0, 0, 0.75)
# What an eliminated player's chip fades to for the rest of the round.
const DEAD_MODULATE := Color(1, 1, 1, 0.35)

var _row: HBoxContainer
# peer_id -> { root, portrait, name_label, score_label }
var _chips := {}
# Rounds needed to take the match, shown as the denominator on each chip.
var _target := 0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Anchored across the bottom. The win/lose message (UILayer/Overlay/Message)
	# is anchored across the TOP, so the two never overlap.
	anchor_left = 0.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	# Roomier than the chips need. A label carries outline_size 4, which adds to
	# its height on both sides, so a band sized to the portrait alone lets the
	# text overflow and the bottom row gets clipped by the screen edge.
	offset_top = -44.0
	offset_bottom = -10.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN

	_row = HBoxContainer.new()
	_row.name = "Row"
	_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override("separation", 18)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_row)

	visible = false

#####
# Building
#####

# `entries` is an Array of Dictionaries: { peer_id, name, character, score }.
# Rebuilds from scratch, so it is safe to call at the top of every round.
func set_players(entries: Array) -> void:
	clear()

	for entry in entries:
		var peer_id := int(entry.get("peer_id", 0))
		if peer_id == 0 or _chips.has(peer_id):
			continue

		var chip := HBoxContainer.new()
		chip.name = "Chip%d" % peer_id
		chip.add_theme_constant_override("separation", 5)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Centre in the band rather than filling it, so an oversized label grows
		# in both directions instead of pushing the chip off the bottom.
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER

		var portrait := TextureRect.new()
		portrait.texture = Characters.get_portrait(int(entry.get("character", 0)))
		# EXPAND_IGNORE_SIZE or the TextureRect's minimum size is the atlas
		# region itself (76x66) and custom_minimum_size below acts only as a
		# floor -- the portrait renders full size and is clipped by the screen.
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		portrait.custom_minimum_size = Vector2(
			PORTRAIT_HEIGHT * PORTRAIT_ASPECT, PORTRAIT_HEIGHT)
		portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(portrait)

		var name_label := _label(str(entry.get("name", "")), 13, COLOR_NAME)
		chip.add_child(name_label)

		var score_label := _label("", 15, COLOR_SCORE)
		chip.add_child(score_label)

		_row.add_child(chip)
		_chips[peer_id] = {
			root = chip,
			portrait = portrait,
			name_label = name_label,
			score_label = score_label,
		}

		_render_score(peer_id, int(entry.get("score", 0)))

func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	# The chips sit on top of the arena, whose brightness is entirely up to the
	# map, so the text carries its own outline rather than a backing panel.
	label.add_theme_color_override("font_outline_color", COLOR_OUTLINE)
	label.add_theme_constant_override("outline_size", 4)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func clear() -> void:
	for peer_id in _chips:
		var chip: Control = _chips[peer_id].root
		_row.remove_child(chip)
		chip.queue_free()
	_chips.clear()

#####
# State
#####

# Rounds needed to win the match. Shown as "wins/target" so the goal is on
# screen rather than in the settings resource.
func set_target(target: int) -> void:
	_target = max(0, target)
	for peer_id in _chips:
		_render_score(peer_id, _score_of(peer_id))

func set_score(peer_id: int, score: int) -> void:
	if not _chips.has(peer_id):
		return
	_render_score(peer_id, score)

func _render_score(peer_id: int, score: int) -> void:
	var label: Label = _chips[peer_id].score_label
	label.set_meta("score", score)
	if _target > 0:
		label.text = "%d/%d" % [score, _target]
	else:
		label.text = str(score)

func _score_of(peer_id: int) -> int:
	if not _chips.has(peer_id):
		return 0
	return int(_chips[peer_id].score_label.get_meta("score", 0))

# Dims an eliminated player for the rest of the round. The chip stays in place
# rather than disappearing, so the row does not reflow mid-fight and the score
# of a player who is already out is still readable.
func set_alive(peer_id: int, alive: bool) -> void:
	if not _chips.has(peer_id):
		return
	_chips[peer_id].root.modulate = Color.WHITE if alive else DEAD_MODULATE

func reset_alive() -> void:
	for peer_id in _chips:
		_chips[peer_id].root.modulate = Color.WHITE

func has_player(peer_id: int) -> bool:
	return _chips.has(peer_id)

func player_count() -> int:
	return _chips.size()

#####
# Visibility
#####

func show_hud() -> void:
	visible = true

func hide_hud() -> void:
	visible = false
