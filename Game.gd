extends Node2D

var Player = preload("res://actors/Player.tscn")

# The map pool. The host picks one per round and ships the choice to every peer
# alongside the settings, so everyone loads the same arena -- picking
# independently would put players in different levels.
@export var map_scenes: Array[PackedScene] = [
	preload("res://maps/Arena1.tscn"),
	preload("res://maps/Arena2.tscn"),
	preload("res://maps/Arena3.tscn"),
]

# Which entry of map_scenes is currently loaded.
var map_index: int = 0

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
# Round clock state for the HUD. Emitted on every peer, every frame the clock is
# alive, plus once with running = false whenever it is stopped or reset.
signal round_clock_changed (seconds_left, running, sudden_death)
# Raised on each peer the moment sudden death begins, for the warning message.
signal sudden_death_started ()
# Raised once, SUDDEN_DEATH_WARNING_SECONDS before the clock expires, so the
# player is told what is about to happen rather than just dying.
signal sudden_death_warning (seconds_left)
# Carries the round's roster to every peer. Only the host ever calls
# Main.start_game(), so Main.players used to stay empty on clients for the whole
# match; _do_game_setup is the one place that reaches every peer with the roster.
signal roster_updated (players)
# Counts down to the start of a round: 3, 2, 1, then 0 meaning "go". Main turns
# it into the on-screen number.
signal countdown_tick (seconds_left)

# Upper bound on the setup handshake. _do_game_setup() pauses the tree and only
# _do_game_start() unpauses it, so a peer dropping between the two RPCs used to
# leave every peer on a frozen frame with no timeout and no error.
const SETUP_TIMEOUT_SECONDS := 15.0

var _waiting_for_setup := false
# Guards against a second countdown running alongside the first. _do_game_start
# is an RPC and can also be invoked by the setup watchdog, so it is genuinely
# reachable twice for one round.
var _counting_down := false
# Bumped whenever a round is set up or torn down, so the watchdog of an earlier
# round cannot start (or unpause) a round that has since been replaced.
var _setup_generation := 0

#####
# Round clock and sudden death
#
# Rounds used to be able to stall forever: two players who never reach each
# other keep the match hostage. The clock bounds a round, and when it runs out
# the arena itself finishes the job.
#
# HOST-AUTHORITATIVE. Every peer runs a copy of the countdown, but ONLY so the
# HUD has a smooth number to draw. A peer never decides anything from it: the
# host is the only one that fires _do_sudden_death_start, exactly as it is the
# only one that picks the map and ships the settings in _do_game_setup. Peers
# also have their remaining time overwritten by the host once a second, so a
# client whose display has drifted is pulled back rather than diverging for the
# whole round.
#####

const SuddenDeathZoneScript := preload("res://objects/SuddenDeathZone.gd")

# How often the host tells everyone what the clock really says.
const CLOCK_SYNC_INTERVAL := 1.0

# The HUD turns red and the message warns from here on, so sudden death is never
# a surprise.
const SUDDEN_DEATH_WARNING_SECONDS := 10.0

# Fallback play area when a map reports a degenerate rect (Map2 does): the
# bounding box of the living players, grown by this much on every side, so the
# tide still has something to sweep and the round still resolves.
const FALLBACK_RECT_MARGIN := 500.0

var round_clock_running := false
var round_time_left := 0.0
var sudden_death_active := false

var _sudden_death_elapsed := 0.0
var _clock_sync_countdown := 0.0
var _sudden_death_warned := false
var _sudden_death_zone: Node2D = null

func _ready() -> void:
	reload_game_settings()

func game_start(players: Dictionary, characters: Dictionary = {}) -> void:
	# Resources do not serialize over RPC safely, so the settings travel as a
	# plain Dictionary and are rebuilt on each peer.
	var settings_data: Dictionary = get_game_settings().to_dict()
	var chosen_map := _pick_next_map()

	if GameState.online_play:
		rpc('_do_game_setup', players, settings_data, chosen_map, characters)
	else:
		_do_game_setup(players, settings_data, chosen_map, characters)

# Which arenas are still unplayed in the current cycle. Refilled when it empties.
var _map_bag: Array[int] = []

# A shuffled bag rather than either extreme.
#
# Pure random repeats maps and can show the same one three rounds running; a
# strict (map_index + 1) % size is the opposite problem -- with three arenas the
# whole session is one predictable A-B-C loop, and players know the next map
# before the round ends. Drawing without replacement gives every arena an
# outing per cycle while keeping the order unguessable, and never repeats a map
# back-to-back across the seam between cycles.
func _pick_next_map() -> int:
	if map_scenes.is_empty():
		return 0
	if map_scenes.size() == 1:
		return 0

	if _map_bag.is_empty():
		_refill_map_bag()
	return _map_bag.pop_back()

func _refill_map_bag() -> void:
	_map_bag.clear()
	for i in range(map_scenes.size()):
		_map_bag.append(i)
	_map_bag.shuffle()

	# The bag is drawn from the back, so the last element is the next map. If it
	# matches what is loaded, the seam between two cycles would repeat a map --
	# swap it with the front rather than reshuffling until it does not, which
	# could in principle spin forever.
	if _map_bag.size() > 1 and _map_bag[_map_bag.size() - 1] == map_index:
		var last := _map_bag.size() - 1
		var first: int = _map_bag[0]
		_map_bag[0] = _map_bag[last]
		_map_bag[last] = first

func get_map_scene() -> PackedScene:
	if map_scenes.is_empty():
		return null
	return map_scenes[clampi(map_index, 0, map_scenes.size() - 1)]

func get_game_settings() -> GameSettings:
	if game_settings == null:
		game_settings = GameSettings.new()
	return game_settings

# Re-read the player's saved tuning. Called at startup and whenever the settings
# screen saves, so a change takes effect on the next round without a restart.
func reload_game_settings() -> void:
	game_settings = GameSettings.load_saved()

# Initializes the game so that it is ready to really start.
@rpc("any_peer", "call_local") func _do_game_setup(players: Dictionary, settings_data: Dictionary = {}, chosen_map: int = -1, characters: Dictionary = {}) -> void:
	# Adopt the host's tuning before spawning anyone. from_dict() builds a fresh
	# resource rather than mutating the preloaded default, which the resource
	# cache would otherwise keep mutated for the rest of the process.
	if not settings_data.is_empty():
		game_settings = GameSettings.from_dict(settings_data)

	if chosen_map >= 0 and chosen_map < map_scenes.size():
		map_index = chosen_map

	# Tear the previous round down before pausing: game_stop() unpauses, so
	# pausing first would immediately be undone here.
	if game_started:
		game_stop()

	# Belt and braces: game_stop() above already does this, but it only runs
	# when a previous round was in flight. A clock (or a tide) surviving into
	# the next round is exactly the bug class this file keeps producing.
	_reset_round_clock()

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
		other_player.set_player_skin(int(characters.get(peer_id, player_number - 1)))
		other_player.position = map.get_node("PlayerStartPositions/Player" + str(player_number)).position
		other_player.rotation = map.get_node("PlayerStartPositions/Player" + str(player_number)).rotation
		# AFTER the spawn position is set. The name label is top_level and is
		# placed relative to the player's global position, so naming a player
		# still sitting at the origin pinned their label there -- and
		# Player._process(), which re-places it every frame, does not run while
		# the tree is paused, which is exactly what the round countdown does.
		other_player.set_player_name(players[peer_id])
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
	_run_countdown()

# Holds the round for a beat before play begins.
#
# The tree has been paused since _do_game_setup(), and this deliberately leaves
# it that way: players are already spawned and visible, so everyone can see the
# arena and which character is theirs before anything can kill them. Rounds used
# to begin on the very frame the tree unpaused.
#
# Length comes from GameSettings.round_countdown, so it replicates to every peer
# with the rest of the tuning and the tests can set it to 0.
func _run_countdown() -> void:
	if _counting_down:
		return

	var seconds := int(ceil(get_game_settings().round_countdown))
	if seconds <= 0:
		# Disabled entirely: begin play without so much as a "GO!". The tick is
		# deliberately NOT emitted, or a zero countdown would still flash across
		# the screen. Anything that just wants to know play began has
		# game_started_signal.
		get_tree().set_pause(false)
		return

	_counting_down = true
	# A round can be abandoned mid-countdown -- the back button, a peer leaving,
	# the next round being set up -- and the tick that survives that must not
	# unpause a tree that now belongs to a menu.
	var generation := _setup_generation

	for remaining in range(seconds, 0, -1):
		emit_signal("countdown_tick", remaining)
		# create_timer defaults to process_always, so it keeps ticking on the
		# paused tree.
		await get_tree().create_timer(1.0).timeout
		if generation != _setup_generation or not game_started:
			_counting_down = false
			return

	_counting_down = false
	emit_signal("countdown_tick", 0)
	get_tree().set_pause(false)

	# Started HERE and not in _do_game_setup: setup pauses the tree and waits on
	# the handshake (up to SETUP_TIMEOUT_SECONDS), so a clock started there
	# would have the countdown eaten by the handshake -- and on a slow peer the
	# round could reach sudden death before anyone had moved.
	_start_round_clock()

func game_stop() -> void:
	_reset_round_clock()

	if map.has_method('map_stop'):
		map.map_stop()

	game_started = false
	# Any setup watchdog or countdown still in flight belongs to the round we
	# just dropped.
	_waiting_for_setup = false
	_counting_down = false
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
	# Named to avoid shadowing the map_index member, which tracks which arena
	# is loaded rather than where the node sits in the tree.
	var child_index := map.get_index()
	remove_child(map)
	map.queue_free()

	var scene := get_map_scene()
	if scene == null:
		return
	map = scene.instantiate()
	map.name = 'Map'
	add_child(map)
	move_child(map, child_index)

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
		# The round is decided, so the clock and any sudden-death hazard stop
		# here -- not when the next round is set up. A tide left running would
		# keep rising (and killing) through the two seconds of "X wins this
		# round!", and the HUD would keep counting down over the menus.
		_stop_round_clock()
		var player_keys = players_alive.keys()
		emit_signal("game_over_signal", player_keys[0])
	elif not game_over and players_alive.is_empty():
		# Nobody left and no winner declared: the round would sit there forever.
		# Sudden death makes this reachable in a way it was not before -- the
		# tide can take the last two players within the same handful of frames,
		# and a death that arrives while the roster is already down to one
		# lands here. Deaths are still processed one at a time, so the player
		# who died LAST is the survivor by the only measure available, and
		# awarding them the round keeps Main's scoring flow completely normal.
		game_over = true
		_stop_round_clock()
		emit_signal("game_over_signal", peer_id)

#####
# Round clock and sudden death
#####

# True when this peer is allowed to DECIDE things about the clock, as opposed to
# merely displaying it. In local play there is only one machine; online, the
# host is the single source of truth (peer id 1).
func _is_clock_authority() -> bool:
	if not GameState.online_play:
		return true
	var tree := get_tree()
	if tree == null:
		return true
	return tree.get_multiplayer().is_server()

# Called from _do_game_start(), i.e. once the round is genuinely running.
func _start_round_clock() -> void:
	var limit := float(get_game_settings().round_time_limit)
	if limit <= 0.0:
		# 0 disables the feature outright: no countdown, no HUD, no sudden
		# death -- the behaviour the game had before the clock existed.
		_reset_round_clock()
		return

	round_time_left = limit
	round_clock_running = true
	sudden_death_active = false
	_sudden_death_elapsed = 0.0
	_sudden_death_warned = false
	_clock_sync_countdown = CLOCK_SYNC_INTERVAL
	emit_signal("round_clock_changed", round_time_left, true, false)

# Stops the countdown and clears the hazard, but does not pretend the round
# never happened -- used when the round ENDS (someone won).
func _stop_round_clock() -> void:
	round_clock_running = false
	sudden_death_active = false
	_sudden_death_elapsed = 0.0
	_sudden_death_warned = false
	_clear_sudden_death_zone()
	emit_signal("round_clock_changed", 0.0, false, false)

func _reset_round_clock() -> void:
	round_time_left = 0.0
	_clock_sync_countdown = 0.0
	_stop_round_clock()

func _clear_sudden_death_zone() -> void:
	if _sudden_death_zone == null:
		return
	# The tide must stop killing on the FRAME the round ends -- otherwise it
	# keeps rising through the two seconds of "X wins this round!" and takes the
	# winner with it. It cannot simply be freed here: this is reached from
	# inside a physics callback (body_entered -> die() -> game over), and Godot
	# refuses to remove a collision object while it is flushing queries. So it
	# is made inert immediately and deleted on the next idle frame.
	if is_instance_valid(_sudden_death_zone):
		if _sudden_death_zone.has_method("deactivate"):
			_sudden_death_zone.deactivate()
		_sudden_death_zone.queue_free()
	_sudden_death_zone = null

func _process(delta: float) -> void:
	# The tree is paused for the whole setup handshake, so _process does not run
	# then and the clock cannot tick behind a frozen frame.
	if not round_clock_running:
		return

	if sudden_death_active:
		_process_sudden_death(delta)
		return

	round_time_left = maxf(0.0, round_time_left - delta)
	emit_signal("round_clock_changed", round_time_left, true, false)

	# Cosmetic, and therefore fired locally on every peer rather than RPCed:
	# each peer's countdown is pulled back into line by the host once a second,
	# so they all cross the threshold within a second of each other.
	if not _sudden_death_warned and round_time_left <= SUDDEN_DEATH_WARNING_SECONDS:
		_sudden_death_warned = true
		emit_signal("sudden_death_warning", round_time_left)

	if not _is_clock_authority():
		# A client that reaches zero on its own just sits at zero showing
		# 0:00 until the host says otherwise. It must NOT start sudden death:
		# two peers each deciding that independently is how hazards end up in
		# different places on different machines.
		return

	if GameState.online_play:
		_clock_sync_countdown -= delta
		if _clock_sync_countdown <= 0.0:
			_clock_sync_countdown = CLOCK_SYNC_INTERVAL
			rpc("_sync_round_clock", round_time_left)

	if round_time_left <= 0.0:
		if GameState.online_play:
			rpc("_do_sudden_death_start")
		else:
			_do_sudden_death_start()

func _process_sudden_death(delta: float) -> void:
	_sudden_death_elapsed += delta

	# The tide's position is a pure function of the time since sudden death
	# began, so every peer draws it in the same place from the single start
	# message -- no per-frame position syncing, nothing to drift.
	var duration := maxf(0.5, float(get_game_settings().sudden_death_duration))
	var progress := clampf(_sudden_death_elapsed / duration, 0.0, 1.0)
	if _sudden_death_zone != null and is_instance_valid(_sudden_death_zone):
		_sudden_death_zone.set_progress(progress)

	emit_signal("round_clock_changed", 0.0, true, true)

# The host's authoritative reading of the clock. Peers adopt it; nobody else may
# send it.
@rpc("any_peer", "call_local") func _sync_round_clock(seconds_left: float) -> void:
	if not _sender_is_host():
		return
	if not round_clock_running or sudden_death_active:
		return
	round_time_left = maxf(0.0, seconds_left)

# The one decision that starts the hazard, made by the host and broadcast.
@rpc("any_peer", "call_local") func _do_sudden_death_start() -> void:
	if not _sender_is_host():
		return
	if sudden_death_active or not round_clock_running:
		return

	sudden_death_active = true
	round_time_left = 0.0
	_sudden_death_elapsed = 0.0
	_spawn_sudden_death_zone()

	emit_signal("sudden_death_started")
	emit_signal("round_clock_changed", 0.0, true, true)

# Only peer 1 (or a purely local call, sender 0) may drive the clock.
func _sender_is_host() -> bool:
	var tree := get_tree()
	if tree == null:
		return true
	var sender := tree.get_multiplayer().get_remote_sender_id()
	return sender == 0 or sender == 1

func _spawn_sudden_death_zone() -> void:
	_clear_sudden_death_zone()

	var zone: Node2D = SuddenDeathZoneScript.new()
	zone.name = "SuddenDeath"
	add_child(zone)
	zone.setup(_get_sudden_death_rect())
	_sudden_death_zone = zone

# The area the tide has to cover, in global pixels.
func _get_sudden_death_rect() -> Rect2:
	var rect := Rect2()
	if map != null and map.has_method("get_map_rect"):
		rect = map.get_map_rect()
	if rect.size.x > 0.0 and rect.size.y > 0.0:
		return rect

	# A map whose tilemaps report nothing usable (maps/Map2.tscn does) would
	# otherwise leave sudden death with no geometry and the round unresolvable.
	# Fall back to the box the players are actually standing in.
	push_warning("Map reported an empty rect; sudden death falls back to the players' bounds.")
	var bounds := Rect2()
	var found := false
	for child in players_node.get_children():
		if not child.has_method("pickup_or_throw"):
			continue
		if not found:
			bounds = Rect2(child.global_position, Vector2.ZERO)
			found = true
		else:
			bounds = bounds.expand(child.global_position)
	if not found:
		bounds = Rect2(Vector2.ZERO, Vector2.ZERO)
	return bounds.grow(FALLBACK_RECT_MARGIN)
