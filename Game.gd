extends Node2D

var Player = preload("res://actors/Player.tscn")

@export var map_scene: PackedScene = preload("res://maps/Map1.tscn")

# Movement feel and match rules. The host's copy is the one that counts: it is
# shipped to every peer in _do_game_setup() and rebuilt there before any player
# is spawned. Remote players are simulated locally from their replayed input
# buffer, so peers running different numbers drift apart with no error anywhere.
@export var game_settings: GameSettings = preload("res://resources/default_game_settings.tres")

@onready var map: Node2D = $Map
@onready var players_node := $Players
@onready var camera := $Camera2D
@onready var original_camera_position: Vector2 = camera.global_position

var game_started := false
var game_over := false
var players_alive := {}
var players_setup := {}

signal game_started_signal ()
signal player_dead (peer_id)
signal game_over_signal (peer_id)
# Carries the round's roster to every peer. Only the host ever calls
# Main.start_game(), so Main.players used to stay empty on clients for the whole
# match; _do_game_setup is the one place that reaches every peer with the roster.
signal roster_updated (players)

# Upper bound on the setup handshake. _do_game_setup() pauses the tree and only
# _do_game_start() unpauses it, so a peer dropping between the two RPCs used to
# leave every peer on a frozen frame with no timeout and no error.
const SETUP_TIMEOUT_SECONDS := 15.0

var _waiting_for_setup := false
# Bumped whenever a round is set up or torn down, so the watchdog of an earlier
# round cannot start (or unpause) a round that has since been replaced.
var _setup_generation := 0

func _ready() -> void:
	reload_game_settings()

func game_start(players: Dictionary) -> void:
	# Resources do not serialize over RPC safely, so the settings travel as a
	# plain Dictionary and are rebuilt on each peer.
	var settings_data: Dictionary = get_game_settings().to_dict()

	if GameState.online_play:
		rpc('_do_game_setup', players, settings_data)
	else:
		_do_game_setup(players, settings_data)

func get_game_settings() -> GameSettings:
	if game_settings == null:
		game_settings = GameSettings.new()
	return game_settings

# Re-read the player's saved tuning. Called at startup and whenever the settings
# screen saves, so a change takes effect on the next round without a restart.
func reload_game_settings() -> void:
	game_settings = GameSettings.load_saved()

# Initializes the game so that it is ready to really start.
@rpc("any_peer", "call_local") func _do_game_setup(players: Dictionary, settings_data: Dictionary = {}) -> void:
	# Adopt the host's tuning before spawning anyone. from_dict() builds a fresh
	# resource rather than mutating the preloaded default, which the resource
	# cache would otherwise keep mutated for the rest of the process.
	if not settings_data.is_empty():
		game_settings = GameSettings.from_dict(settings_data)

	# Tear the previous round down before pausing: game_stop() unpauses, so
	# pausing first would immediately be undone here.
	if game_started:
		game_stop()

	get_tree().set_pause(true)

	game_started = true
	game_over = false
	# duplicate(): in local play, and on the host in online play (this is a
	# call_local RPC), `players` is the very dictionary Main.gd owns. Without
	# the copy, players_alive.erase() on a death also silently erases from
	# Main.players. It self-heals today only because Main rebuilds that dict
	# each round.
	players_alive = players.duplicate()
	players_setup.clear()

	# Every peer -- not just the host that built it -- learns the roster here.
	emit_signal("roster_updated", players_alive.duplicate())

	reload_map()

	var player_number := 1
	for peer_id in players:
		var other_player = Player.instantiate()
		other_player.name = str(peer_id)
		# Assigned before the node enters the tree so its first physics frame
		# already uses the host's tuning.
		other_player.settings = game_settings
		players_node.add_child(other_player)

		other_player.set_multiplayer_authority(peer_id)
		other_player.set_player_skin(player_number - 1)
		other_player.set_player_name(players[peer_id])
		other_player.position = map.get_node("PlayerStartPositions/Player" + str(player_number)).position
		other_player.rotation = map.get_node("PlayerStartPositions/Player" + str(player_number)).rotation
		other_player.player_dead.connect(Callable(self, "_on_player_dead").bind(peer_id))

		if not GameState.online_play:
			other_player.player_controlled = true
			other_player.input_prefix = "player" + str(player_number) + "_"

		player_number += 1

	camera.update_position_and_zoom(false)

	if GameState.online_play:
		var my_id = get_tree().get_multiplayer().get_unique_id()
		var my_player := players_node.get_node(str(my_id))
		my_player.player_controlled = true

		_waiting_for_setup = true
		_setup_generation += 1
		_watch_setup(_setup_generation)

		# Tell the host that we've finished setup.
		rpc_id(1, '_finished_game_setup', my_id)
	else:
		_do_game_start()

# Records when each player has finished setup so we know when all players are ready.
@rpc("any_peer", "call_local") func _finished_game_setup(peer_id: int) -> void:
	# The argument is whatever the sender chose to send, and it can arrive late --
	# after game_stop() has cleared players_alive, or for a peer that is not in
	# this round at all. Indexing players_alive blindly raised "Invalid index".
	if not players_alive.has(peer_id):
		return

	players_setup[peer_id] = players_alive[peer_id]
	_check_players_setup()

# Once every player still in the round has confirmed setup, start it everywhere.
# Also re-checked when a player dies or drops mid-handshake, because otherwise
# nothing ever re-evaluates the tally and the round stays paused forever.
func _check_players_setup() -> void:
	if not _waiting_for_setup or players_alive.is_empty():
		return
	if not get_tree().get_multiplayer().is_server():
		return
	if players_setup.size() >= players_alive.size():
		rpc('_do_game_start')

# Bounded fallback for the setup handshake. If _do_game_start() has not arrived
# by the time this fires, start anyway rather than leaving every peer staring at
# a paused frame. The timer is created with process_always, so it still ticks
# while the tree is paused.
func _watch_setup(generation: int) -> void:
	await get_tree().create_timer(SETUP_TIMEOUT_SECONDS).timeout

	if generation != _setup_generation or not _waiting_for_setup or not game_started:
		return

	push_warning("Game setup timed out after %ds; starting without the peers that never confirmed." % int(SETUP_TIMEOUT_SECONDS))
	if get_tree().get_multiplayer().is_server():
		rpc('_do_game_start')
	else:
		_do_game_start()

# Actually start the game on this client.
@rpc("any_peer", "call_local") func _do_game_start() -> void:
	_waiting_for_setup = false
	if map.has_method('map_start'):
		map.map_start()
	emit_signal("game_started_signal")
	get_tree().set_pause(false)

func game_stop() -> void:
	if map.has_method('map_stop'):
		map.map_stop()

	game_started = false
	# Any setup watchdog still in flight belongs to the round we just dropped.
	_waiting_for_setup = false
	_setup_generation += 1
	players_setup.clear()
	players_alive.clear()

	for child in players_node.get_children():
		players_node.remove_child(child)
		child.queue_free()

	# A round can be abandoned while the setup handshake still has the tree
	# paused, and a paused tree freezes the menus we are returning to.
	get_tree().set_pause(false)

func reload_map() -> void:
	var map_index = map.get_index()
	remove_child(map)
	map.queue_free()

	map = map_scene.instantiate()
	map.name = 'Map'
	add_child(map)
	move_child(map, map_index)

	var map_rect = map.get_map_rect()
	camera.global_position = original_camera_position
	camera.limit_left = map_rect.position.x
	camera.limit_top = map_rect.position.y
	camera.limit_right = map_rect.position.x + map_rect.size.x
	camera.limit_bottom = map_rect.position.y + map_rect.size.y

# Removes a player whose peer has left the match. die() is gated on
# is_multiplayer_authority(), and the authority of this node is exactly the peer
# that just disconnected -- so on every remaining peer die() silently did
# nothing: the body kept walking, stayed invulnerable, and players_alive never
# lost the key, so the round could never end. force_remove() has no such gate.
func kill_player(peer_id) -> void:
	var player_node = players_node.get_node_or_null(str(peer_id))
	if player_node == null:
		# Already gone (they died just before leaving); still make sure the
		# bookkeeping does not keep them "alive" forever.
		_on_player_dead(peer_id)
		return

	if player_node.has_method("force_remove"):
		player_node.force_remove()
	elif player_node.has_method("die"):
		push_warning("Player has no force_remove(); falling back to die(), which does nothing for a departed peer.")
		player_node.die()
	else:
		# If there is no removal method, we do the most important things it
		# would have done.
		player_node.queue_free()
		_on_player_dead(peer_id)

func _on_player_dead(peer_id) -> void:
	# Idempotent on purpose. Game.tscn connects this node's own player_dead
	# signal back to this method, so the re-emit below re-enters here once; the
	# guard is what stops that from recursing, and it also absorbs a double
	# death report (e.g. a player who dies in the same frame their peer leaves).
	if not players_alive.has(peer_id):
		return

	players_alive.erase(peer_id)
	players_setup.erase(peer_id)

	# Main.tscn wires this signal to Main._on_player_dead ("You lose!"), but
	# nothing ever emitted it, so that handler was dead code.
	emit_signal("player_dead", peer_id)

	# A player dying or dropping mid-handshake must not hold the round hostage.
	_check_players_setup()

	if not game_over and players_alive.size() == 1:
		game_over = true
		var player_keys = players_alive.keys()
		emit_signal("game_over_signal", player_keys[0])
