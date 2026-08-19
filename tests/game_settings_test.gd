extends Node

# Guards the tuning resource that movement feel and match rules now come from.
#
# Two things make this worth an explicit test:
#   - The defaults ARE the game's feel. Nothing else fails if someone nudges
#     `speed` while debugging, so the values are pinned here on purpose: a change
#     to any of them has to be a deliberate edit to this file too.
#   - to_dict()/from_dict() is how the host's settings reach clients (Game.gd
#     ships them with _do_game_setup). A field missing from that round-trip means
#     peers simulate with different numbers and drift apart silently -- remote
#     players are replayed against local physics, so nothing errors.
#
# Runs without a Nakama server and without a match: it exercises the resource
# directly, plus one real Player instance for the fallback path.

const PlayerScene := preload("res://actors/Player.tscn")

var _failures := 0

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[settings] OK: %s" % label)
	else:
		_failures += 1
		print("[settings] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[settings] starting")

	_check_defaults()
	_check_gravity()
	_check_round_trip()
	_check_player_fallback()

	print("[settings] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

# The shipped feel of the game, spelled out.
func _check_defaults() -> void:
	var settings := GameSettings.new()

	_check("default speed", settings.speed, 350.0)
	_check("default acceleration", settings.acceleration, 2000.0)
	_check("default friction", settings.friction, 1500.0)
	_check("default sliding_friction", settings.sliding_friction, 400.0)
	_check("default jump_speed", settings.jump_speed, 700.0)
	_check("default glide_speed", settings.glide_speed, -100.0)
	_check("default terminal_velocity", settings.terminal_velocity, 1000.0)
	_check("default push_back_speed", settings.push_back_speed, 50.0)
	_check("default throw_velocity", settings.throw_velocity, 300.0)
	_check("default throw_upward_velocity", settings.throw_upward_velocity, 500.0)
	_check("default throw_vector_mix", settings.throw_vector_mix, 0.5)
	_check("default throw_vector_max_length", settings.throw_vector_max_length, 700.0)
	_check("default throw_torque", settings.throw_torque, 10.0)
	_check("default rounds_to_win", settings.rounds_to_win, 5)
	_check("default sync_delay", settings.sync_delay, 3)
	_check("default round_countdown", settings.round_countdown, 3.0)

	# The .tres the game actually loads must agree with the script defaults,
	# otherwise editing one of them changes nothing.
	var shipped: GameSettings = load("res://resources/default_game_settings.tres")
	_check_true("default_game_settings.tres loads", shipped != null)
	if shipped != null:
		_check("shipped resource matches the script defaults",
			shipped.to_dict(), settings.to_dict())

# 0 means "fall back to the project setting", which is what Player.gd used to
# read directly; anything positive overrides it.
func _check_gravity() -> void:
	var settings := GameSettings.new()
	var project_gravity := float(ProjectSettings.get_setting(GameSettings.PROJECT_GRAVITY_SETTING))

	_check("gravity is unset by default", settings.gravity, 0.0)
	_check("unset gravity falls back to the project default",
		settings.get_gravity(), project_gravity)

	settings.gravity = 1234.0
	_check("an explicit gravity overrides the project default",
		settings.get_gravity(), 1234.0)

# This is the wire format between host and clients.
func _check_round_trip() -> void:
	var settings := GameSettings.new()

	# Give every field a distinct non-default value, so a field that is dropped
	# on the way through cannot pass by accidentally matching the default.
	var i := 1
	for field in GameSettings.FIELDS:
		var current = settings.get(field)
		if typeof(current) == TYPE_INT:
			settings.set(field, 40 + i)
		else:
			settings.set(field, 11.0 * i)
		i += 1

	var data := settings.to_dict()
	_check("to_dict() carries every field", data.size(), GameSettings.FIELDS.size())

	var rebuilt := GameSettings.from_dict(data)
	_check_true("from_dict() returns a GameSettings", rebuilt is GameSettings)
	_check_true("from_dict() returns a new instance", rebuilt != settings)

	for field in GameSettings.FIELDS:
		_check("round-trips %s" % field, rebuilt.get(field), settings.get(field))

	# A partial dictionary (an older peer, say) must leave the rest at defaults
	# rather than clearing them.
	var partial := GameSettings.from_dict({"speed": 99.0})
	_check("from_dict() applies a partial dictionary", partial.speed, 99.0)
	_check("from_dict() leaves absent fields at their default", partial.jump_speed, 700.0)

# A Player spawned without settings (a test, or a hand-placed scene) must still
# move, not read null.
func _check_player_fallback() -> void:
	var player := PlayerScene.instantiate()
	add_child(player)

	_check_true("a Player without settings gets a fallback resource",
		player.get_settings() != null)
	_check("a Player without settings reports the default speed", player.speed, 350.0)
	_check("a Player without settings reports the default jump_speed", player.jump_speed, 700.0)
	_check("a Player without settings reports the default throw_torque", player.throw_torque, 10.0)
	_check("a Player falls back to the project gravity",
		player.gravity, float(ProjectSettings.get_setting(GameSettings.PROJECT_GRAVITY_SETTING)))

	# An assigned resource must win over the fallback, which is what makes the
	# host's values authoritative on every peer.
	var tuned := GameSettings.new()
	tuned.speed = 777.0
	player.settings = tuned
	_check("an assigned resource overrides the fallback", player.speed, 777.0)

	remove_child(player)
	player.queue_free()
