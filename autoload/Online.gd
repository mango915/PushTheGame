extends Node

# For developers to set from the outside, for example:
#   Online.nakama_host = 'nakama.example.com'
#   Online.nakama_scheme = 'https'
var nakama_server_key: String = 'defaultkey'
var nakama_host: String = '54.37.12.116'
var nakama_port: int = 7350
var nakama_scheme: String = 'http'

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

func _set_readonly_variable(_value) -> void:
	pass

func _ready() -> void:
	# Don't stop processing messages from Nakama when the game is paused.
	Nakama.process_mode = Node.PROCESS_MODE_ALWAYS
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
