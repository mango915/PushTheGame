extends Node

# Exercises the in-game settings: persistence, the derived jump numbers, and
# the screen itself actually building and writing back.
#
# Booting Main.tscn only proves the screen does not crash on load; it does not
# prove a slider changes anything or that a saved value survives a restart.

const SettingsScreenScene := preload("res://main/screens/SettingsScreen.tscn")

var _failures := 0
var _saved_config := ""

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[cfg] OK: %s" % label)
	else:
		_failures += 1
		print("[cfg] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _check_near(label: String, actual: float, expected: float, tolerance: float = 0.5) -> void:
	if abs(actual - expected) <= tolerance:
		print("[cfg] OK: %s" % label)
	else:
		_failures += 1
		print("[cfg] FAIL: %s (expected ~%.2f, got %.2f)" % [label, expected, actual])

func _ready() -> void:
	print("[cfg] starting")
	_saved_config = _read_raw(GameSettings.CONFIG_PATH)

	_check_defaults()
	_check_jump_maths()
	_check_persistence()
	await _check_screen()

	_write_raw(GameSettings.CONFIG_PATH, _saved_config)

	print("[cfg] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

func _check_defaults() -> void:
	GameSettings.clear_saved()
	var settings := GameSettings.load_saved()
	_check("shipped run speed", settings.speed, 350.0)
	_check("shipped jump strength", settings.jump_speed, 700.0)
	_check("shipped rounds to win", settings.rounds_to_win, 5)

func _check_jump_maths() -> void:
	var settings := GameSettings.new()
	settings.jump_speed = 700.0
	settings.speed = 350.0
	settings.gravity = 980.0

	# h = v^2 / 2g -> 700^2 / 1960 = 250
	_check_near("jump height from strength and gravity", settings.get_jump_height(), 250.0)
	# t = 2v / g -> 1400 / 980 = 1.4286
	_check_near("airtime", settings.get_jump_airtime(), 1.4286, 0.01)
	# d = speed * t -> 350 * 1.4286 = 500
	_check_near("jump distance", settings.get_jump_distance(), 500.0)

	# Halving gravity should raise and lengthen the jump, not shorten it.
	var floaty := GameSettings.new()
	floaty.jump_speed = 700.0
	floaty.speed = 350.0
	floaty.gravity = 490.0
	_check_true("lower gravity jumps higher",
		floaty.get_jump_height() > settings.get_jump_height())
	_check_true("lower gravity jumps further",
		floaty.get_jump_distance() > settings.get_jump_distance())

	# gravity = 0 is the "use the project default" sentinel, not literally zero
	# gravity -- which would make the jump maths divide by zero.
	var auto := GameSettings.new()
	auto.gravity = 0.0
	_check_true("gravity sentinel resolves to the project default", auto.get_gravity() > 0.0)
	_check_true("jump height is finite with the sentinel", auto.get_jump_height() > 0.0)

func _check_persistence() -> void:
	GameSettings.clear_saved()

	var settings := GameSettings.load_saved()
	settings.speed = 512.0
	settings.jump_speed = 999.0
	settings.rounds_to_win = 3
	settings.save_to_config()

	var reloaded := GameSettings.load_saved()
	_check("saved run speed survives a reload", reloaded.speed, 512.0)
	_check("saved jump strength survives a reload", reloaded.jump_speed, 999.0)
	_check("saved rounds to win survives a reload", reloaded.rounds_to_win, 3)
	_check("untouched values keep their defaults", reloaded.friction, 1500.0)

	# Saving gameplay values must not wipe the server settings, which live in
	# the same file.
	var config := ConfigFile.new()
	config.load(GameSettings.CONFIG_PATH)
	config.set_value("server", "host", "example.test")
	config.save(GameSettings.CONFIG_PATH)

	var again := GameSettings.load_saved()
	again.speed = 400.0
	again.save_to_config()

	var check := ConfigFile.new()
	check.load(GameSettings.CONFIG_PATH)
	_check("server settings survive a gameplay save",
		check.get_value("server", "host", ""), "example.test")

	GameSettings.clear_saved()
	var cleared := GameSettings.load_saved()
	_check("reset restores the shipped speed", cleared.speed, 350.0)

	var after_clear := ConfigFile.new()
	after_clear.load(GameSettings.CONFIG_PATH)
	_check("reset leaves the server settings alone",
		after_clear.get_value("server", "host", ""), "example.test")

func _check_screen() -> void:
	# The screen builds its UI in code, so this is where a bad node path or a
	# wrong signal signature would surface.
	var screen = SettingsScreenScene.instantiate()
	add_child(screen)
	await get_tree().process_frame

	_check_true("screen built its sliders", screen._sliders.size() > 0)
	_check_true("run speed has a slider", screen._sliders.has("speed"))
	_check_true("jump strength has a slider", screen._sliders.has("jump_speed"))
	_check_true("gravity has a slider", screen._sliders.has("gravity"))
	_check_true("the jump readout says something", screen._jump_readout.text != "")

	# Moving a slider must actually change the settings behind it.
	screen._sliders["speed"].value = 600.0
	await get_tree().process_frame
	_check("moving the slider updates the setting", screen._settings.speed, 600.0)

	# rounds_to_win is an int; a float from the slider must not leak through.
	screen._sliders["rounds_to_win"].value = 7.0
	await get_tree().process_frame
	_check("integer settings stay integers", screen._settings.rounds_to_win, 7)
	_check_true("integer setting is typed as int",
		typeof(screen._settings.rounds_to_win) == TYPE_INT)

	screen.queue_free()

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
