extends Node

# Guards the local profile and server-settings layer that device authentication
# depends on. Runs without a Nakama server: nothing here talks to the network.
#
# What matters: the device id must be STABLE across runs, because it is the
# player's identity. If it regenerates, Nakama creates a brand new account every
# launch and the player silently loses their leaderboard history.

var _failures := 0

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[profile] OK: %s" % label)
	else:
		_failures += 1
		print("[profile] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[profile] starting")

	# Preserve whatever the real user has, so running tests does not clobber a
	# player's identity or server choice.
	var saved_profile := _read_raw(Online.PROFILE_FILENAME)
	var saved_settings := _read_raw(Online.SETTINGS_FILENAME)
	var saved_host := Online.nakama_host
	var saved_port := Online.nakama_port
	var saved_scheme := Online.nakama_scheme

	_run_checks()

	# Restore.
	_write_raw(Online.PROFILE_FILENAME, saved_profile)
	_write_raw(Online.SETTINGS_FILENAME, saved_settings)
	Online.nakama_host = saved_host
	Online.nakama_port = saved_port
	Online.nakama_scheme = saved_scheme

	print("[profile] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

func _run_checks() -> void:
	# A device id must exist and be non-trivial.
	var device_id := Online.get_device_id()
	_check_true("device id is not empty", device_id != "")
	_check_true("device id is long enough to be unique", device_id.length() >= 8)

	# Stability is the whole point: reloading the profile must not mint a new id.
	Online.save_profile()
	Online._load_profile()
	_check("device id is stable across a reload", Online.get_device_id(), device_id)

	# Display name round-trips.
	Online.set_display_name("TestPilot")
	Online._load_profile()
	_check("display name persists", Online.display_name, "TestPilot")

	# An empty name must not wipe the existing one.
	Online.set_display_name("   ")
	_check("blank display name is rejected", Online.display_name, "TestPilot")

	# Server settings round-trip, which is what makes the server field in the UI
	# meaningful rather than cosmetic.
	Online.apply_server_settings("127.0.0.1", 7350, "http")
	_check("host applied", Online.nakama_host, "127.0.0.1")
	_check("port applied", Online.nakama_port, 7350)

	Online.nakama_host = "wrong"
	Online.nakama_port = 1
	Online._load_settings()
	_check("host persisted", Online.nakama_host, "127.0.0.1")
	_check("port persisted", Online.nakama_port, 7350)

	# Changing servers must invalidate the old session.
	_check("session dropped after server change", Online.nakama_session, null)

	# Session helpers must be honest with no session present.
	_check("has_valid_session is false without a session", Online.has_valid_session(), false)

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
