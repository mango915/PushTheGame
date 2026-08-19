extends Node

# Guards the charged bow, ported as a mechanic from the compa_dev branch.
#
# The two things worth pinning down are the two things that branch got wrong for
# this codebase. Its bow reads Input directly inside _physics_process, which
# cannot work when remote players are simulated by replaying an input buffer --
# so the draw here is driven entirely through use()/use_release() and never
# touches Input. And its damage scales with draw force, which needs hit points;
# this game is one hit, so draw force has to buy REACH instead, which means a
# weak shot must actually travel less far.

const BowScene := preload("res://pickups/Bow.tscn")
const PlayerScene := preload("res://actors/Player.tscn")

var _failures := 0
var _world: Node2D

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[bow] OK: %s" % label)
	else:
		_failures += 1
		print("[bow] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[bow] starting")
	GameState.online_play = false
	_world = Node2D.new()
	add_child(_world)
	await get_tree().process_frame

	_check_resource()
	await _check_draw()
	await _check_reach()
	await _check_dropping()

	_world.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	print("[bow] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

func _make_bow() -> Node:
	var bow = BowScene.instantiate()
	_world.add_child(bow)
	return bow

func _arrows() -> Array:
	var found := []
	for c in _world.get_children():
		if c.has_method("launch"):
			found.append(c)
	return found

func _check_resource() -> void:
	var data = load("res://resources/bow_weapon.tres")
	_check_true("bow_weapon.tres loads", data != null)
	_check_true("it is a WeaponData", data is WeaponData)
	_check_true("a full draw takes time", data.draw_seconds > 0.0)
	_check_true("a slack shot is slower than a full one",
		data.min_projectile_velocity < data.projectile_velocity)

	var bow := _make_bow()
	_check("the scene adopts the draw time", bow.draw_seconds, data.draw_seconds)
	_check("it starts loaded", bow.ammo, data.max_ammo)
	bow.queue_free()

func _check_draw() -> void:
	var bow := _make_bow()
	await get_tree().process_frame

	_check("a fresh bow is not drawn", bow.drawing, false)
	bow.use()
	_check_true("use() starts the draw", bow.drawing)

	await get_tree().create_timer(0.2).timeout
	_check_true("the draw builds while held (%.2f)" % bow.draw_amount,
		bow.draw_amount > 0.0)
	var partial: float = bow.draw_amount

	# ...and stops at full rather than running away.
	await get_tree().create_timer(1.2).timeout
	_check("the draw caps at full", bow.draw_amount, 1.0)
	_check_true("it grew on the way there", bow.draw_amount > partial)

	var before := _arrows().size()
	bow.use_release()
	await get_tree().process_frame
	_check("releasing looses one arrow", _arrows().size(), before + 1)
	_check("releasing ends the draw", bow.drawing, false)
	_check("loosing spends an arrow", bow.ammo, bow.max_ammo - 1)

	# Releasing without drawing must not conjure an arrow.
	var n := _arrows().size()
	bow.use_release()
	await get_tree().process_frame
	_check("releasing an undrawn bow does nothing", _arrows().size(), n)

	for a in _arrows(): a.queue_free()
	bow.queue_free()
	await get_tree().process_frame

# Draw force buys reach. This is the whole design: a tap has to fall short.
func _check_reach() -> void:
	var speeds := []
	for amount in [0.0, 1.0]:
		var bow := _make_bow()
		await get_tree().process_frame
		bow.use()
		bow._do_loose(amount)
		await get_tree().process_frame
		var arrows := _arrows()
		_check_true("a %s draw produces an arrow" % ("full" if amount > 0.5 else "slack"),
			arrows.size() > 0)
		if arrows.size() > 0:
			speeds.append(arrows[0].velocity.length())
			for a in arrows: a.free()
		bow.queue_free()
		await get_tree().process_frame

	if speeds.size() == 2:
		_check_true("a full draw flies faster than a tap (%.0f vs %.0f)"
				% [speeds[1], speeds[0]],
			speeds[1] > speeds[0] * 1.5)

	# An arrow arcs: gravity is what turns speed into range.
	var bow2 := _make_bow()
	await get_tree().process_frame
	bow2.use()
	bow2._do_loose(1.0)
	await get_tree().process_frame
	var arrow = _arrows()[0]
	var vy0: float = arrow.velocity.y
	await get_tree().create_timer(0.25).timeout
	if is_instance_valid(arrow):
		_check_true("gravity pulls the arrow down over time (%.0f -> %.0f)"
				% [vy0, arrow.velocity.y],
			arrow.velocity.y > vy0)
		arrow.free()
	bow2.queue_free()
	await get_tree().process_frame

# Being disarmed mid-draw must not fire the shot: nobody aimed it.
func _check_dropping() -> void:
	var bow := _make_bow()
	await get_tree().process_frame
	bow.use()
	await get_tree().create_timer(0.1).timeout
	_check_true("drawn before the throw", bow.drawing)

	var before := _arrows().size()
	bow._on_throw()
	await get_tree().process_frame
	_check("throwing a drawn bow does not fire it", _arrows().size(), before)
	_check("throwing releases the string", bow.drawing, false)

	bow.queue_free()
	await get_tree().process_frame
