extends Node

# Key rebinding.
#
# Everything here fails silently by nature: a rebind that also wipes the joypad
# event, a key left firing two actions, a "reset" that restores the last saved
# bindings instead of the shipped ones -- none of them error, they just make the
# controls wrong in a way that reads as the game being broken. So they are
# pinned as invariants rather than trusted.

var _failures := 0
var _saved := {}

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[keys] OK: %s" % label)
	else:
		_failures += 1
		print("[keys] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[keys] starting")

	# Snapshot every rebindable action so this test cannot leak state into
	# whatever runs next in the same process.
	for action in Keybinds.rebindable_actions():
		_saved[action] = InputMap.action_get_events(action).duplicate()

	_check_actions()
	_check_rebind_keeps_joypad()
	_check_conflicts()
	_check_reserved()
	_check_clear_and_reset()
	_check_persistence()

	_restore()
	print("[keys] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

func _restore() -> void:
	for action in _saved:
		for event in InputMap.action_get_events(action):
			InputMap.action_erase_event(action, event)
		for event in _saved[action]:
			InputMap.action_add_event(action, event)
	Keybinds.clear_saved()

func _joypad_events(action: String) -> int:
	var n := 0
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton or event is InputEventJoypadMotion:
			n += 1
	return n

#####

func _check_actions() -> void:
	var actions := Keybinds.rebindable_actions()
	_check("both keyboard seats are rebindable",
		actions.size(), Keybinds.PREFIXES.size() * Keybinds.ACTIONS.size())
	# Seats 3 and 4 are gamepad-only; offering them here would present bindings
	# that the title screen says do not exist.
	for action in actions:
		_check_true("%s is a keyboard seat" % action,
			action.begins_with("player1_") or action.begins_with("player2_"))
	_check_true("jump ships with two keys bound",
		Keybinds.keys_for("player1_jump")[1] != 0)

# The regression that matters most: _apply() erases KEY events to replace them,
# and an over-broad erase would silently take the gamepad with it.
func _check_rebind_keeps_joypad() -> void:
	var pads_before := _joypad_events("player1_jump")
	_check_true("player1_jump has a pad binding to protect", pads_before > 0)

	Keybinds.set_key("player1_jump", 0, KEY_T)
	_check("rebinding leaves the pad binding alone",
		_joypad_events("player1_jump"), pads_before)
	_check_true("the new key is bound", KEY_T in Keybinds.keys_for("player1_jump"))

	# Physical, not unicode: WASD must stay put on AZERTY.
	var physical := false
	for event in InputMap.action_get_events("player1_jump"):
		if event is InputEventKey and event.physical_keycode == KEY_T:
			physical = true
	_check_true("the binding is stored as a physical keycode", physical)

func _check_conflicts() -> void:
	Keybinds.set_key("player1_left", 0, KEY_G)
	_check("a free key reports no conflict",
		Keybinds.conflict_for(KEY_H, "player1_left"), "")
	_check("a taken key names its owner",
		Keybinds.conflict_for(KEY_G, "player1_right"), "player1_left")

	# Stealing must actually remove the old binding. Leaving both would make one
	# key fire two actions, which looks like a broken game rather than a
	# misconfigured one.
	var taken := Keybinds.set_key("player1_right", 0, KEY_G)
	_check("stealing reports who lost the key", taken, "player1_left")
	_check_true("the key now fires only the new action",
		not (KEY_G in Keybinds.keys_for("player1_left")))
	_check_true("...and does fire it", KEY_G in Keybinds.keys_for("player1_right"))

func _check_reserved() -> void:
	var before: Array = Keybinds.keys_for("player1_use")
	var result := Keybinds.set_key("player1_use", 0, KEY_ESCAPE)
	_check("Escape is refused", result, "reserved")
	_check("...and the old binding survives", Keybinds.keys_for("player1_use"), before)

func _check_clear_and_reset() -> void:
	Keybinds.clear_key("player1_blop", 0)
	_check("a cleared slot is empty", Keybinds.keys_for("player1_blop")[0], 0)

	# Reset must restore what project.godot shipped, not the last thing saved --
	# reading defaults from the live InputMap would make this a no-op.
	Keybinds.reset_to_defaults()
	_check_true("reset restores the shipped jump keys",
		KEY_SPACE in Keybinds.keys_for("player1_jump"))
	_check_true("...including the alternate", KEY_W in Keybinds.keys_for("player1_jump"))
	_check_true("reset drops a rebind", not (KEY_T in Keybinds.keys_for("player1_jump")))
	_check("reset keeps the pad binding", _joypad_events("player1_jump") > 0, true)

func _check_persistence() -> void:
	Keybinds.set_key("player1_grab", 0, KEY_Y)
	Keybinds.save()

	# Wipe it from the live map, then reload: proves load_saved() is what put it
	# back rather than it merely never having left.
	Keybinds.reset_to_defaults()
	_check_true("reset cleared the saved key",
		not (KEY_Y in Keybinds.keys_for("player1_grab")))

	Keybinds.load_saved()
	_check_true("a saved binding survives a reload",
		KEY_Y in Keybinds.keys_for("player1_grab"))

	# The file is shared with GameSettings and Online -- writing keybinds must
	# not blow their sections away.
	var settings := GameSettings.load_saved()
	_check_true("saving keybinds leaves gameplay settings intact",
		settings.speed > 0.0)

	Keybinds.clear_saved()
	Keybinds.reset_to_defaults()
