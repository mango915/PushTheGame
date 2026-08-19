extends Node

# Map effect zones: launch pads, pits, ice and tar.
#
# These are physics reactions applied locally on every peer, so a bug here shows
# up as players behaving differently on different machines rather than as an
# error. Worth pinning down.

const PlayerScene := preload("res://actors/Player.tscn")
const EffectZoneScene := preload("res://objects/EffectZone.tscn")

var _failures := 0
var _world: Node2D

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[zone] OK: %s" % label)
	else:
		_failures += 1
		print("[zone] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[zone] starting")
	GameState.online_play = false

	_world = Node2D.new()
	add_child(_world)
	await get_tree().process_frame

	await _check_launch()
	await _check_slippery()
	await _check_sticky()
	await _check_kill()
	_check_composition()

	print("[zone] %d assertion(s) failed" % _failures)

	# Tear the scratch world down before quitting.
	#
	# Every check above frees its player and zone with queue_free(), which is
	# DEFERRED -- and _world itself was never freed at all. Quitting on the same
	# frame left the whole deletion queue unprocessed, so the engine reported
	# "Resources still in use at exit". scripts/check.sh greps for a bare
	# "ERROR: ", so that failed the entire run -- intermittently, since whether
	# the queue happened to flush first depends on frame timing. Freeing the
	# parent and giving the tree two frames to process the queue makes it
	# deterministic. Deliberately not silenced in check.sh's IGNORE_PATTERN:
	# the diagnostic is worth keeping for real leaks.
	_world.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame

	get_tree().quit(0)

func _make_player() -> Node:
	var player = PlayerScene.instantiate()
	_world.add_child(player)
	player.player_controlled = false
	return player

func _make_zone(effect: int) -> Node:
	var zone = EffectZoneScene.instantiate()
	zone.effect = effect
	_world.add_child(zone)
	return zone

# A launch pad must send a player up harder than their own jump, and must not
# have that velocity stomped by the Jump state it puts them into.
func _check_launch() -> void:
	var player := _make_player()
	var zone := _make_zone(EffectZone.Effect.LAUNCH)
	zone.launch_speed = 1150.0
	await get_tree().process_frame

	# The pad also fires from its own _process for anyone overlapping it, and
	# the player and zone are both at the origin here -- so it may already have
	# launched during the frame above, leaving the rate limiter armed and this
	# explicit call a no-op. Clear it so we are testing the pad, not the race.
	zone._last_launch.clear()
	player.vector = Vector2(0, 200.0)
	zone._try_launch(player)

	# Checked before any physics frame runs: one tick of gravity (1500/60 = 25)
	# is applied immediately afterwards, so asserting the exact value after an
	# await is measuring gravity, not the pad.
	_check("launch sets upward velocity", player.vector.y, -1150.0)
	_check_true("launch beats a normal jump",
		absf(player.vector.y) > player.jump_speed)

	await get_tree().process_frame
	_check_true("the player is still travelling upward a frame later",
		player.vector.y < -1000.0)
	_check("launch puts the player in the Jump state",
		player.state_machine.current_state.name, "Jump")

	# The relaunch delay stops a pad machine-gunning someone standing on it.
	player.vector.y = 0.0
	zone._try_launch(player)
	_check("relaunch is rate limited", player.vector.y, 0.0)

	player.queue_free()
	zone.queue_free()
	await get_tree().process_frame

# Ice: much less friction, so players slide instead of stopping dead.
func _check_slippery() -> void:
	var player := _make_player()
	var zone := _make_zone(EffectZone.Effect.SLIPPERY)
	zone.friction_scale = 0.12
	await get_tree().process_frame

	var normal_friction: float = player.friction
	player.enter_effect_zone(zone)
	_check_true("ice reduces friction", player.friction < normal_friction)
	_check("ice scales friction by the zone's factor",
		snappedf(player.friction, 0.01), snappedf(normal_friction * 0.12, 0.01))

	player.exit_effect_zone(zone)
	_check("leaving the ice restores friction", player.friction, normal_friction)

	player.queue_free()
	zone.queue_free()
	await get_tree().process_frame

# Tar: slower, and you cannot jump out of it.
func _check_sticky() -> void:
	var player := _make_player()
	var zone := _make_zone(EffectZone.Effect.STICKY)
	zone.speed_scale = 0.55
	await get_tree().process_frame

	var normal_speed: float = player.speed
	_check("jumping is allowed normally", player.jump_blocked, false)

	player.enter_effect_zone(zone)
	_check_true("tar slows the player", player.speed < normal_speed)
	_check("tar blocks jumping", player.jump_blocked, true)

	player.exit_effect_zone(zone)
	_check("leaving the tar restores speed", player.speed, normal_speed)
	_check("leaving the tar restores jumping", player.jump_blocked, false)

	player.queue_free()
	zone.queue_free()
	await get_tree().process_frame

# A pit kills whoever falls in.
func _check_kill() -> void:
	var player := _make_player()
	var zone := _make_zone(EffectZone.Effect.KILL)
	await get_tree().process_frame

	var died := [false]
	player.player_dead.connect(func(): died[0] = true)

	zone._on_body_entered(player)
	await get_tree().process_frame
	await get_tree().process_frame

	_check("falling into a pit kills the player", died[0], true)

	zone.queue_free()
	await get_tree().process_frame

# Overlapping zones must compose, and leaving one must not cancel the other.
func _check_composition() -> void:
	var player := _make_player()
	var ice := _make_zone(EffectZone.Effect.SLIPPERY)
	var tar := _make_zone(EffectZone.Effect.STICKY)

	player.enter_effect_zone(ice)
	player.enter_effect_zone(tar)
	_check_true("both effects apply at once",
		player.friction_scale < 1.0 and player.speed_scale < 1.0)
	_check("stacked zones still block jumping", player.jump_blocked, true)

	player.exit_effect_zone(tar)
	_check_true("leaving one zone keeps the other", player.friction_scale < 1.0)
	_check("leaving the tar unblocks jumping", player.jump_blocked, false)

	# A zone freed underneath the player must not strand its effect.
	ice.free()
	player._recompute_zone_effects()
	_check("a freed zone releases its effect", player.friction_scale, 1.0)

	player.queue_free()
	tar.queue_free()
