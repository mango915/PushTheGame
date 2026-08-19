extends Node

# Guards UILayer's screen tracking.
#
# current_screen / current_screen_name used to carry an empty setter, so every
# assignment inside show_screen() was discarded and current_screen_name was
# permanently ''. Nothing errored -- the Back button just silently could not
# return to the title screen in online play. Only an explicit test catches this.

const MainScene := preload("res://Main.tscn")

var _failures := 0

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[ui] OK: %s" % label)
	else:
		_failures += 1
		print("[ui] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[ui] starting")
	var main = MainScene.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var ui_layer = main.get_node("UILayer")

	# UILayer._ready shows the title screen.
	_check("title screen is tracked at boot", ui_layer.current_screen_name, "TitleScreen")
	_check_true("current_screen is set", ui_layer.current_screen != null)

	ui_layer.show_screen("MatchScreen")
	await get_tree().process_frame
	_check("switching screens updates the name", ui_layer.current_screen_name, "MatchScreen")
	_check("current_screen points at the shown screen",
		ui_layer.current_screen.name, "MatchScreen")

	# The name is what Main._on_UILayer_back_button branches on: if it never
	# matches, online play can never get back to the title screen.
	_check_true("name matches the Back button's list",
		ui_layer.current_screen_name in ["ConnectionScreen", "MatchScreen", "CreditsScreen"])

	ui_layer.show_screen("SettingsScreen")
	await get_tree().process_frame
	_check("settings screen is tracked", ui_layer.current_screen_name, "SettingsScreen")

	ui_layer.hide_screen()
	await get_tree().process_frame
	_check("hiding clears the tracked screen", ui_layer.current_screen_name, "")

	main.queue_free()
	print("[ui] %d assertion(s) failed" % _failures)
	get_tree().quit(0)
