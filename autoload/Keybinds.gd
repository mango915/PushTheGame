extends Node

# Keyboard rebinding for the two keyboard seats.
#
# Only players 1 and 2 appear here: seats 3 and 4 are gamepad-only by design
# (see TitleScreen.KEYBOARD_PLAYERS), and a pad has no rebinding problem worth a
# UI. Joypad events are therefore left strictly alone -- this only ever adds and
# removes InputEventKey, so an action's pad binding survives every rebind and
# every reset.
#
# Bindings are PHYSICAL keycodes, not unicode ones. WASD has to stay in the same
# place on an AZERTY keyboard, where a layout-dependent binding would scatter it.
#
# Two slots per action, because "jump" genuinely wants both Space and W and
# collapsing that to one binding would take away something the game already had.

signal bindings_changed

const CONFIG_PATH := "user://settings.cfg"
const CONFIG_SECTION := "keybinds"

const SLOTS := 2

const PREFIXES := ["player1_", "player2_"]
const ACTIONS := ["left", "right", "down", "jump", "grab", "use", "blop"]

const ACTION_LABELS := {
	"left": "Left",
	"right": "Right",
	"down": "Duck / drop through",
	"jump": "Jump",
	"grab": "Pick up / throw",
	"use": "Use weapon",
	"blop": "Taunt",
}

# Escape cancels a capture and opens the pause menu. Binding it to a gameplay
# action would leave a player no way out of the capture prompt they are standing
# in, so it is refused rather than offered and then regretted.
const RESERVED_KEYS := [KEY_ESCAPE]

# The InputMap as project.godot authored it, snapshotted before anything saved
# is applied over the top. "Reset to defaults" has to restore THESE, not
# whatever happens to be loaded -- reading the live InputMap for defaults would
# make reset a no-op the moment a binding was saved.
var _defaults := {}

func _ready() -> void:
	for action in rebindable_actions():
		_defaults[action] = _keyboard_keycodes(action)
	load_saved()

#####
# Queries
#####

func rebindable_actions() -> Array:
	var out := []
	for prefix in PREFIXES:
		for action in ACTIONS:
			var name: String = prefix + action
			if InputMap.has_action(name):
				out.append(name)
	return out

func label_for(action: String) -> String:
	for prefix in PREFIXES:
		if action.begins_with(prefix):
			return ACTION_LABELS.get(action.substr(prefix.length()), action)
	return action

# Physical keycodes bound to an action, in slot order. Padded to SLOTS with 0 so
# callers can index a slot without checking length.
func keys_for(action: String) -> Array:
	var keys := _keyboard_keycodes(action)
	while keys.size() < SLOTS:
		keys.append(0)
	return keys.slice(0, SLOTS)

# The physical -> layout translation is a windowing-server call, and the
# HEADLESS server does not implement it. Calling it unguarded logs an engine
# ERROR per key, which is 28 of them before the title screen even appears -- and
# scripts/check.sh greps for a bare "ERROR: ", so it failed every gate in the
# suite including ones with nothing to do with input. Exactly the Godot 3 -> 4
# pattern CLAUDE.md warns about: parses clean, dies on the frame it runs.
#
# The fallback names the physical code directly. That is correct on a US layout
# and only cosmetically wrong on others -- this string is a label, never a
# binding, so a headless run losing layout awareness costs nothing.
func key_name(keycode: int) -> String:
	if keycode == 0:
		return "--"
	var code := keycode
	if DisplayServer.get_name() != "headless":
		code = DisplayServer.keyboard_get_keycode_from_physical(keycode)
	return OS.get_keycode_string(code)

# Which other action already uses this key, or "" if it is free. Silently
# double-binding a key makes the game look broken rather than misconfigured, so
# the screen checks before committing.
func conflict_for(keycode: int, exclude_action: String) -> String:
	if keycode == 0:
		return ""
	for action in rebindable_actions():
		if action == exclude_action:
			continue
		if keycode in _keyboard_keycodes(action):
			return action
	return ""

func is_reserved(keycode: int) -> bool:
	return keycode in RESERVED_KEYS

#####
# Mutation
#####

# Returns "" on success, or the name of the action that already owns the key.
func set_key(action: String, slot: int, keycode: int,
		steal: bool = true) -> String:
	if is_reserved(keycode):
		return "reserved"
	var clash := conflict_for(keycode, action)
	if clash != "" and not steal:
		return clash
	if clash != "":
		# Take it from the other action rather than leaving both bound. A key
		# that fires two actions is worse than a seat with one binding missing,
		# and the screen reports what it took.
		var other := keys_for(clash)
		for i in range(other.size()):
			if other[i] == keycode:
				other[i] = 0
		_apply(clash, other)

	var keys := keys_for(action)
	if slot >= 0 and slot < keys.size():
		keys[slot] = keycode
	_apply(action, keys)
	emit_signal("bindings_changed")
	return clash

func clear_key(action: String, slot: int) -> void:
	var keys := keys_for(action)
	if slot >= 0 and slot < keys.size():
		keys[slot] = 0
	_apply(action, keys)
	emit_signal("bindings_changed")

func reset_to_defaults() -> void:
	for action in _defaults:
		_apply(action, _defaults[action].duplicate())
	emit_signal("bindings_changed")

#####
# Persistence
#####

func save() -> void:
	var config := ConfigFile.new()
	# Load first: GameSettings and Online keep their own sections in this same
	# file, and writing a fresh ConfigFile would drop both.
	config.load(CONFIG_PATH)
	for action in rebindable_actions():
		config.set_value(CONFIG_SECTION, action, _keyboard_keycodes(action))
	config.save(CONFIG_PATH)

func load_saved() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	for action in rebindable_actions():
		if not config.has_section_key(CONFIG_SECTION, action):
			continue
		var stored = config.get_value(CONFIG_SECTION, action)
		if stored is Array or stored is PackedInt32Array:
			var keys := []
			for k in stored:
				keys.append(int(k))
			_apply(action, keys)
	emit_signal("bindings_changed")

func clear_saved() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	if config.has_section(CONFIG_SECTION):
		config.erase_section(CONFIG_SECTION)
	config.save(CONFIG_PATH)

#####
# InputMap
#####

func _keyboard_keycodes(action: String) -> Array:
	var out := []
	if not InputMap.has_action(action):
		return out
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			var code: int = event.physical_keycode
			if code == 0:
				code = event.keycode
			if code != 0 and not (code in out):
				out.append(code)
	return out

# Replace an action's KEY events, leaving every other event type in place.
func _apply(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		return
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			InputMap.action_erase_event(action, event)
	for code in keys:
		if int(code) == 0:
			continue
		var event := InputEventKey.new()
		event.physical_keycode = int(code)
		InputMap.action_add_event(action, event)
