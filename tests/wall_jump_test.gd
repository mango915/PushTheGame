extends Node

# Guards the wall jump, ported as a mechanic from the compa_dev branch.
#
# The interesting invariant is not that it launches you -- it is that it SHOVES
# YOU OFF the wall. Without that, a wall is a free ladder and every arena's
# layout stops meaning anything: the maps are generated against a documented
# jump budget and proved reachable against it, so a move that ignores vertical
# limits entirely would quietly invalidate all of that.

const PlayerScene := preload("res://actors/Player.tscn")

var _failures := 0
var _world: Node2D

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[wall] OK: %s" % label)
	else:
		_failures += 1
		print("[wall] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[wall] starting")
	GameState.online_play = false
	_world = Node2D.new()
	add_child(_world)
	await get_tree().process_frame

	_check_settings()
	await _check_kick()
	await _check_disabled()
	await _check_gated()

	_world.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	print("[wall] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

func _make_player() -> Node:
	var player = PlayerScene.instantiate()
	_world.add_child(player)
	player.player_controlled = false
	return player

func _check_settings() -> void:
	var s := GameSettings.new()
	# Below a standing jump on purpose -- a wall jump that matched one would
	# make any vertical surface a ladder.
	_check_true("a wall jump is weaker than a standing jump",
		s.wall_jump_speed < s.jump_speed)
	_check_true("it shoves you off the wall", s.wall_jump_push > 0.0)
	_check_true("both fields replicate to peers",
		"wall_jump_speed" in GameSettings.FIELDS and "wall_jump_push" in GameSettings.FIELDS)

	# ...and it round-trips, or peers simulate different movement and drift
	# apart with no error anywhere.
	s.wall_jump_speed = 123.0
	s.wall_jump_push = 45.0
	var rebuilt := GameSettings.from_dict(s.to_dict())
	_check("wall_jump_speed survives the wire", rebuilt.wall_jump_speed, 123.0)
	_check("wall_jump_push survives the wire", rebuilt.wall_jump_push, 45.0)

func _check_kick() -> void:
	var player := _make_player()
	await get_tree().process_frame

	# A wall on the player's RIGHT: its normal points left.
	player.state_machine.change_state("WallJump", { "wall_normal": Vector2.LEFT })
	_check("kicking off puts the player in WallJump",
		player.state_machine.current_state.name, "WallJump")
	_check_true("the kick launches upward (%.0f)" % player.vector.y,
		player.vector.y < 0.0)
	_check("the kick is exactly the configured strength",
		player.vector.y, -player.wall_jump_speed)
	_check_true("...and pushes AWAY from the wall (%.0f)" % player.vector.x,
		player.vector.x < 0.0)
	_check("the push is exactly the configured strength",
		player.vector.x, -player.wall_jump_push)

	# Mirrored: a wall on the LEFT throws you right.
	player.state_machine.change_state("Fall")
	player.state_machine.change_state("WallJump", { "wall_normal": Vector2.RIGHT })
	_check_true("a wall on the left throws you right", player.vector.x > 0.0)

	# It must not out-climb a standing jump.
	_check_true("a wall jump does not beat a standing jump",
		absf(player.vector.y) < player.jump_speed)

	player.queue_free()
	await get_tree().process_frame

# 0 turns the move off entirely, so it can be taken out without touching code.
func _check_disabled() -> void:
	var player := _make_player()
	await get_tree().process_frame
	player.settings = GameSettings.new()
	player.settings.wall_jump_speed = 0.0
	_check("a zero wall_jump_speed disables the move", player.can_wall_jump(), false)
	player.queue_free()
	await get_tree().process_frame

# The gate has to refuse the cases that would make it a free ride.
func _check_gated() -> void:
	var player := _make_player()
	await get_tree().process_frame

	# Not touching anything: nothing to kick off.
	_check("no wall, no wall jump", player.can_wall_jump(), false)

	# Tar blocks jumping, and must block this too, or STICKY zones are escapable
	# by hugging their edge.
	player.jump_blocked = true
	_check("tar blocks wall jumping as well", player.can_wall_jump(), false)
	player.jump_blocked = false

	player.queue_free()
	await get_tree().process_frame
