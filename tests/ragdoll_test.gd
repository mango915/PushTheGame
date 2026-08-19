extends Node

# Guards the death cosmetics: the ragdoll corpse, its impulse, and the fact that
# it stays cosmetic.
#
# The corpse is spawned by Player._explode_and_free(), which sits inside a death
# path that is already networked and authority-gated. Everything here therefore
# checks two things at once: that the new effect happens, and that it did not
# disturb the old path --
#
#   * exactly ONE explosion per death (it used to be spawned twice, once here
#     and once in Dead._state_enter, and the gibs are a child of the corpse
#     precisely so they cannot be miscounted as a second one),
#   * a corpse is not a player: Camera.gd and Game.gd pick real players out of
#     the Players container with has_method("pickup_or_throw"), so anything
#     parented there that answers to that name would drag the camera and hold
#     the round open,
#   * force_remove() still works with no authority at all, which is the whole
#     reason it exists (a disconnected peer's player is nobody's authority, so
#     die() silently does nothing on every machine).
#
# Runs headless, with no map and no server: players are dropped into a bare
# container that stands in for Game.tscn's Players node.

const PlayerScene := preload("res://actors/Player.tscn")
const CorpseScene := preload("res://actors/Corpse.tscn")
const CorpseScript := preload("res://actors/Corpse.gd")
const CameraScript := preload("res://Camera.gd")

var _failures := 0
var _players: Node2D

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[ragdoll] OK: %s" % label)
	else:
		_failures += 1
		print("[ragdoll] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _ready() -> void:
	print("[ragdoll] starting")
	GameState.online_play = false

	_players = Node2D.new()
	_players.name = "Players"
	add_child(_players)

	await _test_quiet_death()
	await _test_impulse_direction()
	await _test_not_a_player()
	await _test_bounce_and_settle()
	await _test_cap()
	await _test_fade_and_cleanup()
	await _test_force_remove_without_authority()

	print("[ragdoll] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

# --- helpers ----------------------------------------------------------------

func _spawn_player(skin: int, pos: Vector2) -> Node:
	var player = PlayerScene.instantiate()
	_players.add_child(player)
	player.set_player_skin(skin)
	player.global_position = pos
	return player

# The exact filter Camera.gd and Game.gd/smoke_test.gd use.
func _real_players() -> Array:
	var result := []
	for child in _players.get_children():
		if child.has_method("pickup_or_throw"):
			result.append(child)
	return result

func _explosions() -> Array:
	var result := []
	for child in _players.get_children():
		if child is CPUParticles2D:
			result.append(child)
	return result

func _corpses() -> Array:
	var result := []
	for corpse in get_tree().get_nodes_in_group(CorpseScript.GROUP):
		if is_instance_valid(corpse) and not corpse.is_queued_for_deletion():
			result.append(corpse)
	return result

# queue_free() only takes effect at the end of the frame, and a freed node stays
# in its groups until then, so every count in this suite has to be taken after a
# flush rather than in the frame the death happened.
func _flush() -> void:
	await get_tree().physics_frame
	await get_tree().process_frame

func _clear_corpses() -> void:
	for corpse in _corpses():
		corpse.queue_free()
	await _flush()

# --- tests ------------------------------------------------------------------

# A death with nothing pushing it: one explosion, one corpse wearing the dead
# player's character, and a body that simply drops.
func _test_quiet_death() -> void:
	var player := _spawn_player(1, Vector2(0, 0))
	await get_tree().physics_frame
	await get_tree().physics_frame

	# Through the state machine, exactly as a real death goes
	# (Dead._state_enter -> Player.die() -> _do_die() -> _explode_and_free()).
	player.state_machine.change_state("Dead")

	var corpses := _corpses()
	_check("a death leaves exactly one corpse", corpses.size(), 1)
	if corpses.is_empty():
		return
	var corpse = corpses[0]

	_check("a death still makes exactly one explosion", _explosions().size(), 1)
	_check("corpse carries the dead player's character", corpse.character_index, 1)
	_check("corpse wears that character's sheet",
		corpse.body_sprite.texture.resource_path, Characters.TEXTURES[1])
	_check("corpse names the character it came from",
		corpse.get_character_name(), Characters.character_name(1))

	# Nothing hit this player, so the body is not launched -- it keeps the
	# downward momentum it already had.
	_check_true("an unpushed corpse drops rather than flying up",
		corpse.linear_velocity.y >= 0.0)

	# The gibs live under the corpse, not in the Players container, so they can
	# never be counted as a second explosion.
	_check_true("gibs are emitting", corpse.gibs.emitting)
	_check("gibs are parented to the corpse, not the container",
		corpse.gibs.get_parent(), corpse)

	await _flush()
	_check("the dead player is gone from the container", _real_players().size(), 0)
	_check("the corpse outlives the player it came from", is_instance_valid(corpse), true)

	await _clear_corpses()
	for explosion in _explosions():
		explosion.queue_free()
	await _flush()

# A corpse must fly AWAY from whatever killed it, on both sides, and must
# actually travel that way over the following frames.
func _test_impulse_direction() -> void:
	var attacker := Node2D.new()
	add_child(attacker)

	for direction in [-1.0, 1.0]:
		# Attacker on one side, so the push-back points to the other.
		attacker.global_position = Vector2(-60.0 * direction, 0)
		var player := _spawn_player(0, Vector2.ZERO)
		await get_tree().physics_frame

		player.hurt(attacker)
		_check("being hit enters the Hurt state",
			player.state_machine.current_state.name, "Hurt")
		_check_true("the hit is recorded for the corpse",
			signf(player.last_hit_vector.x) == direction)

		player.state_machine.change_state("Dead")
		var corpses := _corpses()
		if corpses.size() != 1:
			_check("one corpse per hit death", corpses.size(), 1)
			await _clear_corpses()
			continue
		var corpse = corpses[0]
		var start_x: float = corpse.global_position.x

		_check_true("corpse is launched away from the attacker (dir %d)" % int(direction),
			signf(corpse.linear_velocity.x) == direction)
		_check_true("a hit death pops the body upward",
			corpse.linear_velocity.y < 0.0)
		_check_true("the launch is much stronger than the living push-back",
			absf(corpse.linear_velocity.x) > player.push_back_speed * 2.0)
		_check_true("the body is tumbling", absf(corpse.angular_velocity) > 0.0)

		# Not just an initial value: it has to keep travelling that way. Ten
		# physics frames is far more than the one frame of gravity that would
		# pass whatever the horizontal impulse was.
		for i in range(10):
			await get_tree().physics_frame
		if is_instance_valid(corpse):
			var travelled: float = corpse.global_position.x - start_x
			_check_true("corpse actually travels away from the attacker (dir %d)" % int(direction),
				signf(travelled) == direction and absf(travelled) > 20.0)
		else:
			_check("corpse survives its first ten frames", false, true)

		await _clear_corpses()
		for explosion in _explosions():
			explosion.queue_free()
		await _flush()

	attacker.queue_free()

# The corpse shares the Players container with real players. Everything that
# reads that container asks has_method("pickup_or_throw") first, so a corpse
# must not answer to it -- nor to anything else that would make it part of the
# match.
func _test_not_a_player() -> void:
	var player := _spawn_player(3, Vector2(500, 0))
	await get_tree().physics_frame

	var corpse = CorpseScene.instantiate()
	_players.add_child(corpse)
	corpse.global_position = Vector2(-500, 0)
	corpse.setup(3, Vector2.ZERO, Vector2.ZERO, false)

	_check_true("a real player answers the player filter",
		player.has_method("pickup_or_throw"))
	_check_true("a corpse does not answer the player filter",
		not corpse.has_method("pickup_or_throw"))
	_check_true("a corpse cannot be hurt", not corpse.has_method("hurt"))
	_check_true("a corpse cannot be picked up", not corpse.has_method("can_pickup"))
	_check("nothing can collide with a corpse", corpse.collision_layer, 0)
	_check_true("but the corpse still collides with terrain", corpse.collision_mask != 0)
	_check("the container holds one player and one corpse",
		_real_players().size(), 1)

	# The real camera: it must frame the player alone. If the corpse counted,
	# the centre would be pulled back towards the middle.
	var camera = Camera2D.new()
	camera.set_script(CameraScript)
	add_child(camera)
	camera.player_container_path = camera.get_path_to(_players)
	camera.update_position_and_zoom(false)
	_check_true("the camera ignores the corpse when framing the shot",
		absf(camera.global_position.x - player.global_position.x) < 1.0)
	camera.queue_free()

	player.queue_free()
	await _clear_corpses()

# A body thrown at the ground has to stop on it, not sink through it and not
# jitter forever. Uses a stand-in floor on the terrain layer, since this suite
# runs without a map.
func _test_bounce_and_settle() -> void:
	await _clear_corpses()

	const FLOOR_TOP := 300.0

	var floor_body := StaticBody2D.new()
	floor_body.collision_layer = 1
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(4000, 200)
	shape.shape = rect
	# Origin of the body sits at the middle of the slab.
	floor_body.global_position = Vector2(0, FLOOR_TOP + 100.0)
	floor_body.add_child(shape)
	add_child(floor_body)

	var corpse = CorpseScene.instantiate()
	_players.add_child(corpse)
	corpse.global_position = Vector2(0, 0)
	corpse.setup(0, Vector2.ZERO, Vector2(220, 320), false)

	# Run until it settles, with a generous bound. Asserting after a fixed
	# handful of frames would only measure whichever part of the arc we happened
	# to land on.
	var frames := 0
	while frames < 400 and is_instance_valid(corpse) and not corpse.resting:
		await get_tree().physics_frame
		frames += 1

	if is_instance_valid(corpse):
		_check_true("a thrown body comes to rest on terrain (%d frames)" % frames,
			corpse.resting)
		_check_true("it rests on top of the floor rather than through it",
			corpse.global_position.y < FLOOR_TOP)
		_check_true("it travelled sideways before landing",
			corpse.global_position.x > 20.0)
	else:
		_check("the corpse survived long enough to land", false, true)

	floor_body.queue_free()
	await _clear_corpses()

# Corpses are capped so a long round does not fill the arena with bodies, and it
# is the OLDEST that goes.
func _test_cap() -> void:
	await _clear_corpses()

	var spawned := []
	for i in range(CorpseScript.MAX_CORPSES + 3):
		var corpse = CorpseScene.instantiate()
		_players.add_child(corpse)
		corpse.global_position = Vector2(i * 40, 0)
		corpse.setup(i % Characters.count(), Vector2.ZERO, Vector2.ZERO, false)
		spawned.append(corpse)
		# One frame apart so their ages differ and "oldest" is well defined.
		await get_tree().physics_frame

	await _flush()

	_check_true("corpses are capped (%d alive, cap %d)" % [_corpses().size(), CorpseScript.MAX_CORPSES],
		_corpses().size() <= CorpseScript.MAX_CORPSES)
	_check_true("the oldest corpse is the one removed",
		not is_instance_valid(spawned[0]))
	_check_true("the newest corpse survives",
		is_instance_valid(spawned[spawned.size() - 1]))

	await _clear_corpses()

# Bodies fade out and remove themselves, so they cannot accumulate even below
# the cap.
func _test_fade_and_cleanup() -> void:
	var corpse = CorpseScene.instantiate()
	_players.add_child(corpse)
	corpse.setup(0, Vector2.ZERO, Vector2.ZERO, false)
	# The shipped LIFETIME is seconds long; shorten it rather than sitting here.
	corpse.lifetime = 0.2

	await get_tree().physics_frame
	await get_tree().physics_frame
	if is_instance_valid(corpse):
		_check_true("the corpse fades as its lifetime runs out", corpse.modulate.a < 1.0)

	await get_tree().create_timer(0.5).timeout
	await _flush()
	_check_true("the corpse removes itself once its lifetime is up",
		not is_instance_valid(corpse))
	_check("no corpses are left behind", _corpses().size(), 0)

# force_remove() is the disconnected-peer path: the player belongs to a peer
# that is gone, so NOBODY is its authority and die() would do nothing anywhere.
# It must still work, still not RPC, and now also still leave a body.
func _test_force_remove_without_authority() -> void:
	GameState.online_play = true

	var player := _spawn_player(2, Vector2(0, 0))
	player.set_multiplayer_authority(999)
	await get_tree().physics_frame

	_check_true("the test player really has no authority here",
		not player.is_multiplayer_authority())

	player.force_remove()

	_check("force_remove() still makes exactly one explosion", _explosions().size(), 1)
	var corpses := _corpses()
	_check("force_remove() leaves a corpse", corpses.size(), 1)
	if corpses.size() == 1:
		_check("that corpse wears the departed player's character",
			corpses[0].character_index, 2)

	await _flush()
	_check("force_remove() removed the player", _real_players().size(), 0)

	GameState.online_play = false
	await _clear_corpses()
