extends Node

# Where the server settings and the local player profile live. Both are plain
# ConfigFiles under user:// so a player can point the game at their own Nakama
# server without touching code, and keeps the same identity between sessions.
const SETTINGS_FILENAME := 'user://settings.cfg'
const PROFILE_FILENAME := 'user://profile.cfg'

# Defaults. These are overridden by SETTINGS_FILENAME when present, and may be
# changed at runtime via apply_server_settings().
#
# For developers to set from the outside, for example:
#   Online.nakama_host = 'nakama.example.com'
#   Online.nakama_scheme = 'https'
var nakama_server_key: String = 'defaultkey'
var nakama_host: String = '54.37.12.116'
var nakama_port: int = 7350
var nakama_scheme: String = 'http'

# The name other players see. Persisted; defaults to a generated one.
var display_name: String = ''

# Stable per-installation id used for device authentication.
var _device_id: String = ''

# For other scripts to access:
#var nakama_client: NakamaClient: get = get_nakama_client, set = _set_readonly_variable
var nakama_client: NakamaClient
var nakama_session: NakamaSession: set = set_nakama_session
var nakama_socket: NakamaSocket

# Internal variable for initializing the socket.
var _nakama_socket_connecting := false

signal session_changed (nakama_session)
signal session_connected (nakama_session)
signal socket_connected (nakama_socket)
signal socket_error (message)
# Emitted after a connection attempt resolves, either way.
signal socket_settled ()
signal auth_error (message)

func _set_readonly_variable(_value) -> void:
	pass

func _ready() -> void:
	# Don't stop processing messages from Nakama when the game is paused.
	Nakama.process_mode = Node.PROCESS_MODE_ALWAYS
	_load_settings()
	_load_profile()
	if nakama_client == null:
		nakama_client = Nakama.create_client(
				nakama_server_key,
				nakama_host,
				nakama_port,
				nakama_scheme,
				Nakama.DEFAULT_TIMEOUT,
				NakamaLogger.LOG_LEVEL.ERROR)

func get_nakama_client() -> NakamaClient:
	if nakama_client == null:
		nakama_client = Nakama.create_client(
			nakama_server_key,
			nakama_host,
			nakama_port,
			nakama_scheme,
			Nakama.DEFAULT_TIMEOUT,
			NakamaLogger.LOG_LEVEL.ERROR)
	return nakama_client

func set_nakama_session(_nakama_session: NakamaSession) -> void:
	nakama_session = _nakama_session

	emit_signal("session_changed", nakama_session)

	if nakama_session and not nakama_session.is_exception() and not nakama_session.is_expired():
		emit_signal("session_connected", nakama_session)

# Returns true once the socket is usable, false if connecting failed.
#
# Callers should await the return value rather than awaiting the
# socket_connected signal: on failure that signal never fires, so awaiting it
# hangs the caller forever.
func connect_nakama_socket() -> bool:
	if nakama_socket != null:
		return true
	if _nakama_socket_connecting:
		# Another caller is already connecting; wait for whichever way it lands.
		await socket_settled
		return nakama_socket != null

	_nakama_socket_connecting = true
	nakama_socket = Nakama.create_socket_from(nakama_client)
	var connected : NakamaAsyncResult = await nakama_socket.connect_async(nakama_session)
	_nakama_socket_connecting = false

	# Previously this emitted socket_connected unconditionally, so callers
	# happily went on to drive a socket that had failed to connect.
	if connected.is_exception():
		nakama_socket = null
		emit_signal("socket_error", str(connected))
		emit_signal("socket_settled")
		return false

	emit_signal("socket_connected", nakama_socket)
	emit_signal("socket_settled")
	return true

func is_nakama_socket_connected() -> bool:
	return nakama_socket != null && nakama_socket.is_connected_to_host()


#####
# Server settings
#####

func _load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_FILENAME) != OK:
		return
	nakama_host = config.get_value('server', 'host', nakama_host)
	nakama_port = int(config.get_value('server', 'port', nakama_port))
	nakama_scheme = config.get_value('server', 'scheme', nakama_scheme)
	nakama_server_key = config.get_value('server', 'server_key', nakama_server_key)

func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value('server', 'host', nakama_host)
	config.set_value('server', 'port', nakama_port)
	config.set_value('server', 'scheme', nakama_scheme)
	config.set_value('server', 'server_key', nakama_server_key)
	config.save(SETTINGS_FILENAME)

# Point the game at a different Nakama server. Drops any existing session and
# socket, since they belong to the old server.
func apply_server_settings(host: String, port: int, scheme: String = 'http', server_key: String = '') -> void:
	nakama_host = host.strip_edges()
	nakama_port = port
	nakama_scheme = scheme
	if server_key != '':
		nakama_server_key = server_key
	save_settings()

	if nakama_socket:
		nakama_socket.close()
	nakama_socket = null
	nakama_session = null
	# Force the client to be rebuilt against the new address.
	nakama_client = null
	get_nakama_client()

#####
# Local profile / identity
#####

func _load_profile() -> void:
	var config := ConfigFile.new()
	var loaded := config.load(PROFILE_FILENAME) == OK
	if loaded:
		_device_id = config.get_value('profile', 'device_id', '')
		display_name = config.get_value('profile', 'display_name', '')

	if _device_id == '':
		# OS.get_unique_id() is unavailable on some platforms (notably web),
		# where it returns "" -- fall back to a generated id so device auth
		# still gives this installation a stable identity.
		_device_id = OS.get_unique_id()
		if _device_id == '':
			_device_id = _generate_id()
	if display_name == '':
		display_name = 'Player' + str(randi() % 9000 + 1000)
	if not loaded or not config.has_section('profile'):
		save_profile()

func save_profile() -> void:
	var config := ConfigFile.new()
	config.set_value('profile', 'device_id', _device_id)
	config.set_value('profile', 'display_name', display_name)
	config.save(PROFILE_FILENAME)

func set_display_name(name: String) -> void:
	name = name.strip_edges()
	if name == '':
		return
	display_name = name
	save_profile()

func _generate_id() -> String:
	var characters := '0123456789abcdef'
	var result := ''
	for i in range(32):
		result += characters[randi() % characters.length()]
	return result

func get_device_id() -> String:
	return _device_id

#####
# Authentication
#####

# Silent device authentication: no email, no password, no account screen.
# Nakama creates the account on first sight of this device id and returns the
# same user for it thereafter.
#
# Returns true on success. On failure the caller gets the message via the
# returned bool plus auth_error.
func authenticate_device() -> bool:
	var session = await get_nakama_client().authenticate_device_async(
		_device_id, display_name, true)

	if session.is_exception():
		var message := "Could not sign in"
		var exception = session.get_exception()
		if exception and exception.message != '':
			message = exception.message
		nakama_session = null
		emit_signal("auth_error", message)
		return false

	nakama_session = session
	return true

# True when we hold a session that is still good.
func has_valid_session() -> bool:
	return nakama_session != null \
		and not nakama_session.is_exception() \
		and not nakama_session.is_expired()

# Ensures there is a usable session, authenticating by device if needed.
func ensure_session() -> bool:
	if has_valid_session():
		return true
	return await authenticate_device()
