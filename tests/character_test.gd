extends Node

# Character selection: the choice persists, travels between peers, and is what
# the player actually spawns as.
#
# The travelling part matters most. A Nakama presence carries a username but no
# character, so if the announcement were ever dropped, everyone would silently
# render everyone else as the same whale -- which looks like a rendering bug
# rather than a networking one.

const PlayerScene := preload("res://actors/Player.tscn")
const PickerScript = preload("res://main/screens/CharacterPicker.gd")

var _failures := 0
var _saved_profile := ""

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[char] OK: %s" % label)
	else:
		_failures += 1
		print("[char] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[char] starting")
	_saved_profile = _read_raw(Online.PROFILE_FILENAME)

	_check_catalogue()
	_check_persistence()
	_check_player_object()
	await _check_picker()
	await _check_spawned_player()

	_write_raw(Online.PROFILE_FILENAME, _saved_profile)
	print("[char] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

func _check_catalogue() -> void:
	_check("there are four characters", Characters.count(), 4)
	_check_true("every character has a name",
		Characters.character_name(0) != "" and Characters.character_name(3) != "")

	# Out-of-range indices must wrap rather than crash: they arrive over the
	# network from another peer's profile.
	_check("index wraps past the end", Characters.clamp_index(4), 0)
	_check("negative index wraps", Characters.clamp_index(-1), 3)

	var portrait := Characters.get_portrait(1)
	_check_true("a portrait is produced", portrait != null)
	_check("the portrait is one frame, not the whole sheet",
		portrait.region.size, Characters.FRAME_SIZE)

func _check_persistence() -> void:
	Online.set_character(2)
	_check("the choice is applied", Online.character_index, 2)
	Online._load_profile()
	_check("the choice survives a reload", Online.character_index, 2)

	Online.set_character(-3)
	_check_true("a negative choice is not stored", Online.character_index >= 0)

func _check_player_object() -> void:
	# The character has to ride along with the player over the wire.
	var player = OnlineMatch.Player.new("session-1", "Tester", 7, 3)
	_check("character is carried on the player", player.character, 3)

	var round_tripped = OnlineMatch.Player.from_dict(player.to_dict())
	_check("character survives a dict round trip", round_tripped.character, 3)
	_check("peer id survives a dict round trip", round_tripped.peer_id, 7)

	# An older peer that does not send a character must not break the decode.
	var legacy = OnlineMatch.Player.from_dict({
		"session_id": "s", "username": "Old", "peer_id": 9,
	})
	_check("a missing character defaults rather than erroring", legacy.character, 0)

	var lan = OnlineMatch.Player.from_lan(4, "LanPlayer", 1)
	_check("LAN players carry a character too", lan.character, 1)

func _check_picker() -> void:
	var picker := HBoxContainer.new()
	picker.set_script(PickerScript)
	add_child(picker)
	await get_tree().process_frame

	_check("the picker shows every character", picker.get_child_count(), Characters.count())

	var chosen := [-1]
	picker.character_selected.connect(func(i): chosen[0] = i)

	picker.set_selected(1)
	_check("selection is reflected", picker.get_selected(), 1)

	picker._on_pressed(3)
	_check("clicking a character selects it", picker.get_selected(), 3)
	_check("clicking announces the choice", chosen[0], 3)

	# The selected one must be visually distinct, or the player cannot tell
	# which is theirs.
	_check_true("the selected character is highlighted",
		picker.get_child(3).modulate != picker.get_child(0).modulate)

	picker.queue_free()
	await get_tree().process_frame

func _check_spawned_player() -> void:
	var player = PlayerScene.instantiate()
	add_child(player)
	await get_tree().process_frame

	player.set_player_skin(3)
	_check("the player takes the chosen skin", player.player_skin, 3)
	_check_true("the sprite actually changed",
		player.body_sprite.texture == player.skin_resources[3])

	# The name label was an unimplemented stub for a long time; without it you
	# cannot tell who is who in a four-player match.
	player.set_player_name("Kuba")
	await get_tree().process_frame
	_check_true("a name label exists", player._name_label != null)
	_check("the label shows the name", player._name_label.text, "Kuba")

	# Flipping the player negates scale.x, which would mirror the text with it.
	player.set_flip_h(true)
	await get_tree().process_frame
	# top_level, so the label must be unaffected by the player's flipped scale.
	_check_true("the label ignores the player's transform", player._name_label.top_level)
	_check("the name is not mirrored when the player turns",
		player._name_label.scale.x, 1.0)

	# ...and it must still track the player as they move.
	player.global_position = Vector2(400, -120)
	player._update_name_label()
	await get_tree().process_frame

	# "Above the player" has to mean above the SPRITE, not merely above the
	# origin. The origin is at the whale's feet and BodySprite spans roughly
	# y = -64..+2 around it, so a label anywhere down to y = -64 is still drawn
	# across the character's own body -- which is exactly where it used to sit,
	# at y = -46, passing a `dy < 0` check the whole time.
	var sprite_top: float = player.body_sprite.position.y \
		+ player.body_sprite.offset.y \
		- (Characters.FRAME_SIZE.y * 0.5)
	var label_bottom: float = player._name_label.global_position.y \
		+ player._name_label.size.y \
		- player.global_position.y
	_check_true("the label clears the sprite (bottom %.0f, sprite top %.0f)"
			% [label_bottom, sprite_top],
		label_bottom <= sprite_top)
	_check_true("the label follows the player horizontally",
		absf(player._name_label.global_position.x - 400.0) < 60.0)

	player.queue_free()
	await get_tree().process_frame

func _read_raw(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	var text := f.get_as_text()
	f.close()
	return text

func _write_raw(path: String, text: String) -> void:
	if text == "":
		DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
