extends Node

# Guards the Duck-Game-style weapon set: thrown-weapon damage, the shotgun, the
# grenade, the mine and the laser.
#
# Everything here is driven directly rather than through a running match, so the
# assertions are about what each mechanic GUARANTEES, not about how many frames
# something happened to take. Fuses and arming delays are advanced by calling
# _physics_process() with an explicit delta; the physics queries (blast radius,
# beam raycast) are given real bodies in the real 2D world and a couple of
# physics frames to register, then asked once.

var _failures := 0

# Pickup.original_parent is typed Node2D, so weapons have to be parented to one
# exactly as they are in a map -- not straight onto this test root.
var _holder := Node2D.new()

const GUN_SCENE := preload("res://pickups/Gun.tscn")
const SWORD_SCENE := preload("res://pickups/Sword.tscn")
const SHOTGUN_SCENE := preload("res://pickups/Shotgun.tscn")
const GRENADE_SCENE := preload("res://pickups/Grenade.tscn")
const MINE_SCENE := preload("res://pickups/Mine.tscn")
const LASER_SCENE := preload("res://pickups/Laser.tscn")
const PROJECTILE_SCENE := preload("res://pickups/Projectile.tscn")

const HITBOX_SCRIPT := preload("res://components/Hitbox.gd")

# 1-BASED physics layers, as named in project.godot.
const ENVIRONMENT_LAYER := 1
const PLAYER_LAYER := 2
const ONE_WAY_LAYER := 5

# ---------------------------------------------------------------------------
# A stand-in for actors/Player.tscn.
#
# The real Player is not used here on purpose: it runs its own state machine and
# gravity every frame, which would put timing between these assertions and the
# thing they are asserting about. This has exactly the surface the weapons touch
# -- a body on the Player physics layer, hurt(), vector, and a state machine
# whose current state name changes when it is hurt (components/Hitbox.gd reads
# that to decide whether a hit actually landed).
# ---------------------------------------------------------------------------

class FakeState:
	extends RefCounted
	var name := "Idle"

class FakeStateMachine:
	extends RefCounted
	var current_state := FakeState.new()

class Victim:
	extends CharacterBody2D

	var hurts := 0
	var last_source: Node = null
	var vector := Vector2.ZERO
	var state_machine := FakeStateMachine.new()
	var invincible := false

	func _init() -> void:
		collision_layer = 0
		collision_mask = 0
		set_collision_layer_value(2, true)
		var shape := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 16.0
		shape.shape = circle
		add_child(shape)

	func hurt(node: Node2D) -> void:
		if invincible:
			return
		if state_machine.current_state.name == "Hurt":
			return
		hurts += 1
		last_source = node
		state_machine.current_state.name = "Hurt"
		# Same shape as Player.hurt(): a small shove away from the source.
		vector = (global_position - node.global_position).normalized() * 50.0

func _make_victim(at: Vector2) -> Victim:
	var victim := Victim.new()
	_holder.add_child(victim)
	victim.global_position = at
	return victim

func _make_static_body(at: Vector2, size: Vector2, layer: int) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = 0
	body.collision_mask = 0
	body.set_collision_layer_value(layer, true)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	body.add_child(shape)
	_holder.add_child(body)
	body.global_position = at
	return body

func _add(scene: PackedScene) -> Node:
	var node = scene.instantiate()
	_holder.add_child(node)
	return node

# ---------------------------------------------------------------------------

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[weapons] OK: %s" % label)
	else:
		_failures += 1
		print("[weapons] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_near(label: String, actual: float, expected: float, tolerance: float = 0.01) -> void:
	if absf(actual - expected) <= tolerance:
		print("[weapons] OK: %s" % label)
	else:
		_failures += 1
		print("[weapons] FAIL: %s (expected %s +/- %s, got %s)" % [label, str(expected), str(tolerance), str(actual)])

func _ready() -> void:
	print("[weapons] starting")

	add_child(_holder)
	# Let the bodies added above register with the physics server before
	# anything queries the space.
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check_resources()
	_check_thrown_damage_arming()
	await _check_thrower_immunity()
	_check_shotgun_pattern()
	_check_knockback()
	await _check_grenade()
	await _check_mine()
	await _check_laser()
	_check_round_teardown()
	await _check_carry_rotation()
	await _check_held_hand()

	print("[weapons] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

# ---------------------------------------------------------------------------
# 1. The shipped numbers.
#
# Every new weapon is a .tres plus a scene, so the tuning can drift with nothing
# in a code diff to show it. Both ends are checked: the resource on disk, and a
# live instance of the scene that is supposed to be applying it.
# ---------------------------------------------------------------------------

func _check_resources() -> void:
	var shotgun_data = load("res://resources/shotgun_weapon.tres")
	_check_true("shotgun resource is a WeaponData", shotgun_data is WeaponData)
	_check("shotgun pellet_count", shotgun_data.pellet_count, 6)
	_check("shotgun spread_degrees", shotgun_data.spread_degrees, 26.0)
	_check("shotgun knockback", shotgun_data.knockback, 900.0)
	_check("shotgun knockback_up", shotgun_data.knockback_up, 340.0)
	_check("shotgun recoil", shotgun_data.recoil, 260.0)
	_check("shotgun is short range", shotgun_data.projectile_range, 190.0)
	_check("shotgun cooldown_time", shotgun_data.cooldown_time, 0.8)
	_check("shotgun max_ammo", shotgun_data.max_ammo, 2)
	_check("shotgun throw_damage_speed", shotgun_data.throw_damage_speed, 420.0)

	var grenade_data = load("res://resources/grenade_weapon.tres")
	_check_true("grenade resource is a WeaponData", grenade_data is WeaponData)
	_check("grenade fuse_time", grenade_data.fuse_time, 2.0)
	_check("grenade blast_radius", grenade_data.blast_radius, 130.0)
	_check("grenade bounces off geometry", grenade_data.bounce, 0.45)

	var mine_data = load("res://resources/mine_weapon.tres")
	_check_true("mine resource is a WeaponData", mine_data is WeaponData)
	_check("mine arm_delay", mine_data.arm_delay, 1.5)
	_check("mine trigger_radius", mine_data.trigger_radius, 55.0)
	_check("mine blast_radius", mine_data.blast_radius, 100.0)

	var laser_data = load("res://resources/laser_weapon.tres")
	_check_true("laser resource is a WeaponData", laser_data is WeaponData)
	_check("laser beam_range", laser_data.beam_range, 1600.0)
	_check("laser beam_duration", laser_data.beam_duration, 0.16)
	_check("laser recharges slowly", laser_data.cooldown_time, 2.5)
	_check("laser max_ammo", laser_data.max_ammo, 4)

	# The two weapons that shipped first must not have been retuned by any of
	# this: they carry no thrown-damage values, so their SCENES supply them.
	var gun_data = load("res://resources/gun_weapon.tres")
	_check("gun resource still has no pellet override", gun_data.pellet_count, 0)
	_check("gun resource still has no knockback", gun_data.knockback, 0.0)
	_check("gun resource still fires one shot per 0.3s", gun_data.cooldown_time, 0.3)

	# And the instances actually apply what the resources say.
	var shotgun = _add(SHOTGUN_SCENE)
	_check_true("shotgun scene carries its weapon_data", shotgun.weapon_data != null)
	_check("shotgun instance pellet_count", shotgun.pellet_count, 6)
	_check("shotgun instance spread_degrees", shotgun.spread_degrees, 26.0)
	_check("shotgun instance knockback", shotgun.knockback, 900.0)
	_check("shotgun instance recoil", shotgun.recoil, 260.0)
	_check("shotgun instance projectile_range", shotgun.projectile_range, 190.0)
	_check("shotgun starts with two shells", shotgun.ammo, 2)
	_check("shotgun cooldown timer uses cooldown_time", shotgun.get_node("CooldownTimer").wait_time, 0.8)

	var grenade = _add(GRENADE_SCENE)
	_check("grenade instance fuse_time", grenade.fuse_time, 2.0)
	_check("grenade instance blast_radius", grenade.blast_radius, 130.0)
	_check("grenade instance bounce", grenade.bounce, 0.45)

	var mine = _add(MINE_SCENE)
	_check("mine instance arm_delay", mine.arm_delay, 1.5)
	_check("mine instance trigger_radius", mine.trigger_radius, 55.0)

	var laser = _add(LASER_SCENE)
	_check("laser instance beam_range", laser.beam_range, 1600.0)
	_check("laser instance beam_duration", laser.beam_duration, 0.16)
	_check("laser starts charged", laser.ammo, 4)
	_check("laser cooldown timer uses cooldown_time", laser.get_node("CooldownTimer").wait_time, 2.5)
	# Without this connection allow_shoot never comes back and the laser fires
	# exactly once per match.
	_check("the laser's recharge is wired up",
		laser.get_node("CooldownTimer").timeout.get_connections().size(), 1)

	# The shotgun inherits Gun.tscn, so it must have inherited the firing
	# machinery too -- the "Shoot" animation carries the method track that calls
	# _fire_projectile().
	_check_true("the shotgun inherited the gun's Shoot animation",
		shotgun.get_node("AnimationPlayer").has_animation("Shoot"))
	_check_true("...and the barrel it fires from", shotgun.has_node("ProjectilePosition"))

	# The gun is unchanged by the new fields.
	var gun = _add(GUN_SCENE)
	_check("gun still fires a single projectile", gun.pellet_count, 1)
	_check("gun still has no spread", gun.spread_degrees, 0.0)
	_check("gun still has no knockback", gun.knockback, 0.0)
	_check("gun still starts with three shots", gun.ammo, 3)

	for node in [shotgun, grenade, mine, laser, gun]:
		node.queue_free()

# ---------------------------------------------------------------------------
# 2. Thrown weapons hurt -- but only while they are actually travelling.
# ---------------------------------------------------------------------------

func _arm_as_thrown(pickup: Node, speed: float) -> void:
	pickup.pickup_state = Pickup.PickupState.THROWN
	pickup.sleeping = false
	pickup.linear_velocity = Vector2.RIGHT * speed

func _check_thrown_damage_arming() -> void:
	var gun = _add(GUN_SCENE)
	var sword = _add(SWORD_SCENE)

	_check("thrown gun needs 420px/s to kill", gun.throw_damage_speed, 420.0)
	_check("thrown sword needs only 260px/s", sword.throw_damage_speed, 260.0)
	_check_true("a heavy sword is deadlier than a light gun",
		sword.throw_damage_speed < gun.throw_damage_speed)

	_check_true("a weapon that has not been thrown is harmless", not gun.is_thrown_lethal())

	_arm_as_thrown(gun, 600.0)
	_check_true("a fast thrown gun is lethal", gun.is_thrown_lethal())

	# The same speed the gun has already lost interest in still kills with the
	# sword: this is the whole point of the per-weapon threshold.
	_arm_as_thrown(gun, 300.0)
	_arm_as_thrown(sword, 300.0)
	_check_true("a gun slowed to 300px/s is harmless", not gun.is_thrown_lethal())
	_check_true("a sword at 300px/s still kills", sword.is_thrown_lethal())

	# It must stop being lethal once it settles, or every weapon on the floor is
	# instant death.
	_arm_as_thrown(gun, 600.0)
	gun.sleeping = true
	_check_true("a sleeping weapon is harmless", not gun.is_thrown_lethal())

	_arm_as_thrown(gun, 600.0)
	gun.pickup_state = Pickup.PickupState.FREE
	_check_true("a weapon lying free on the floor is harmless", not gun.is_thrown_lethal())

	_arm_as_thrown(gun, 600.0)
	gun.pickup_state = Pickup.PickupState.PICKED_UP
	_check_true("a weapon in someone's hands is not a thrown weapon", not gun.is_thrown_lethal())

	# The detector itself.
	_check_true("a throwable weapon builds a thrown hitbox", gun.thrown_hitbox != null)
	if gun.thrown_hitbox != null:
		_check_true("the thrown hitbox looks for players",
			gun.thrown_hitbox.get_collision_mask_value(PLAYER_LAYER))
		_check_true("the thrown hitbox ignores terrain",
			not gun.thrown_hitbox.get_collision_mask_value(ENVIRONMENT_LAYER))
		_check_true("the thrown hitbox copied the weapon's own shape",
			gun.thrown_hitbox.get_child_count() > 0)

	# An explosive kills with its blast, not on contact, so it grows no hitbox.
	var grenade = _add(GRENADE_SCENE)
	_check("a grenade has no thrown damage", grenade.throw_damage_speed, 0.0)
	_check_true("a grenade grows no thrown hitbox", grenade.thrown_hitbox == null)

	gun.queue_free()
	sword.queue_free()
	grenade.queue_free()

func _check_thrower_immunity() -> void:
	var gun = _add(GUN_SCENE)
	var thrower := _make_victim(Vector2(0, 0))
	var bystander := _make_victim(Vector2(500, 0))
	await get_tree().physics_frame

	# Exactly what Player._do_throw() does.
	gun.pickup(thrower)
	_check("picking up records the holder", gun.player, thrower)
	gun.throw(Vector2.ZERO, Vector2(600, -200), 10.0)

	_check("throwing remembers who let go", gun.thrown_by, thrower)
	_check("the thrower's grace period is the weapon's",
		gun.throw_immunity_left, gun.throw_self_immunity)

	_arm_as_thrown(gun, 600.0)

	# The release frame: the weapon is still inside the thrower.
	gun._on_thrown_hitbox_body_entered(thrower)
	_check("a thrower is not killed by their own release", thrower.hurts, 0)

	# Anyone else is fair game immediately.
	gun._on_thrown_hitbox_body_entered(bystander)
	_check("everyone else is hit straight away", bystander.hurts, 1)

	# The grace period is a grace period, not permanent immunity: run more time
	# through the pickup than throw_self_immunity and the thrower becomes a
	# target like anybody else.
	gun._physics_process(gun.throw_self_immunity + 0.05)
	_check("the grace period expires", gun.throw_immunity_left, 0.0)

	_arm_as_thrown(gun, 600.0)
	gun._on_thrown_hitbox_body_entered(thrower)
	_check("a thrower can be hit by their own weapon later in its flight", thrower.hurts, 1)

	# ...and a weapon that has slowed down hits nobody at all.
	var slow_victim := _make_victim(Vector2(900, 0))
	_arm_as_thrown(gun, 100.0)
	gun._on_thrown_hitbox_body_entered(slow_victim)
	_check("a slow thrown weapon hurts nobody", slow_victim.hurts, 0)

	gun.queue_free()
	thrower.queue_free()
	bystander.queue_free()
	slow_victim.queue_free()

# ---------------------------------------------------------------------------
# 3. Shotgun.
# ---------------------------------------------------------------------------

func _check_shotgun_pattern() -> void:
	var shotgun = _add(SHOTGUN_SCENE)
	var angles: PackedFloat32Array = shotgun.get_pellet_angles()

	_check("a shotgun shot is six pellets", angles.size(), 6)

	var half: float = deg_to_rad(shotgun.spread_degrees) * 0.5
	_check_near("the fan is centred: outermost pellets are symmetric",
		angles[0] + angles[angles.size() - 1], 0.0, 0.0001)
	_check_near("the outermost pellet sits at half the spread",
		angles[angles.size() - 1], half, 0.0001)
	_check_near("the total spread is the configured 26 degrees",
		rad_to_deg(angles[angles.size() - 1] - angles[0]), shotgun.spread_degrees, 0.001)

	var ordered := true
	var within := true
	for i in range(angles.size()):
		if absf(angles[i]) > half + 0.0001:
			within = false
		if i > 0 and angles[i] <= angles[i - 1]:
			ordered = false
	_check_true("pellets are ordered across the fan", ordered)
	_check_true("no pellet leaves the fan", within)

	# The shotgun's own pattern: denser in the middle than an even fan, so a
	# target dead ahead cannot sit in a gap between two middle pellets.
	var even_gap: float = (2.0 * half) / float(angles.size() - 1)
	var middle_gap: float = angles[3] - angles[2]
	_check_true("the pattern has a dense core", middle_gap < even_gap)

	# A single-pellet weapon (the pistol) must be completely unaffected.
	var gun = _add(GUN_SCENE)
	var gun_angles: PackedFloat32Array = gun.get_pellet_angles()
	_check("a pistol still fires one pellet", gun_angles.size(), 1)
	_check("a pistol pellet goes straight down the barrel", gun_angles[0], 0.0)

	shotgun.queue_free()
	gun.queue_free()

func _check_knockback() -> void:
	# The knockback lives on components/Hitbox.gd, which is what every
	# projectile carries, so drive one directly.
	var hitbox := Area2D.new()
	hitbox.set_script(HITBOX_SCRIPT)
	hitbox.knockback = 900.0
	hitbox.knockback_up = 340.0
	_holder.add_child(hitbox)
	hitbox.global_position = Vector2.ZERO

	var victim := _make_victim(Vector2(40, 0))
	hitbox._on_body_entered(victim)
	_check("a shotgun pellet hurts", victim.hurts, 1)
	_check_true("and shoves the victim away from the blast", victim.vector.x > 800.0)
	_check_true("and lofts them off the floor", victim.vector.y < -300.0)

	# A hit that does not land must not shove either.
	var invincible := _make_victim(Vector2(-40, 0))
	invincible.invincible = true
	hitbox._on_body_entered(invincible)
	_check("an invincible player is not hurt", invincible.hurts, 0)
	_check("...and is not shoved either", invincible.vector, Vector2.ZERO)

	# The weapons that shipped before knockback existed must be untouched.
	var plain := Area2D.new()
	plain.set_script(HITBOX_SCRIPT)
	_holder.add_child(plain)
	plain.global_position = Vector2.ZERO
	var plain_victim := _make_victim(Vector2(40, 0))
	plain._on_body_entered(plain_victim)
	_check("a sword hit still only applies the ordinary push back",
		plain_victim.vector, Vector2(50, 0))

	# ...and the projectile passes the weapon's numbers down to its hitbox.
	var projectile = PROJECTILE_SCENE.instantiate()
	_holder.add_child(projectile)
	projectile.shoot(Vector2.ZERO, Vector2(1500, 0), 190.0, false, 900.0, 340.0)
	_check("a projectile carries its weapon's knockback", projectile.hitbox.knockback, 900.0)
	_check("a projectile carries its weapon's lift", projectile.hitbox.knockback_up, 340.0)

	var plain_projectile = PROJECTILE_SCENE.instantiate()
	_holder.add_child(plain_projectile)
	plain_projectile.shoot(Vector2.ZERO, Vector2(1200, 0), 400.0, false)
	_check("an ordinary bullet still has no knockback", plain_projectile.hitbox.knockback, 0.0)

	hitbox.queue_free()
	plain.queue_free()
	victim.queue_free()
	invincible.queue_free()
	plain_victim.queue_free()
	projectile.queue_free()
	plain_projectile.queue_free()

# ---------------------------------------------------------------------------
# 4. Grenade.
# ---------------------------------------------------------------------------

func _check_grenade() -> void:
	var grenade = _add(GRENADE_SCENE)
	grenade.global_position = Vector2(0, -4000)

	# Everyone is placed relative to the grenade: one just inside the radius,
	# one just outside it.
	var near := _make_victim(grenade.global_position + Vector2(60, 0))
	var edge := _make_victim(grenade.global_position + Vector2(129, 0))
	var far := _make_victim(grenade.global_position + Vector2(400, 0))
	# The thrower stands in their own blast. A grenade does not care.
	var thrower := _make_victim(grenade.global_position + Vector2(-40, 0))
	grenade.thrown_by = thrower

	await get_tree().physics_frame
	await get_tree().physics_frame

	# A grenade that has come to rest, which is where most of them go off. It
	# also pins the position: the fuse below is advanced with one big delta, and
	# a grenade still falling would land several thousand pixels from the people
	# this test placed around it. Pickup's physics is deliberately skipped while
	# asleep -- the fuse burning anyway is the guarantee being tested.
	grenade.sleeping = true

	_check_true("a grenade does not start lit", not grenade.fuse_lit)

	grenade.light_fuse()
	_check_true("use() lights the fuse", grenade.fuse_lit)
	_check("the fuse is the configured length", grenade.fuse_left, grenade.fuse_time)

	# Who the blast would catch, before it goes off.
	var caught: Array = grenade.find_bodies_within(grenade.blast_radius)
	_check("the blast radius catches everyone inside it", caught.size(), 3)
	_check_true("...including someone at the very edge", caught.has(edge.get_path()))
	_check_true("...and the thrower", caught.has(thrower.get_path()))
	_check_true("...but nobody outside it", not caught.has(far.get_path()))

	# Not a moment early.
	grenade._physics_process(grenade.fuse_time - 0.1)
	_check_true("a grenade at rest still burns its fuse", grenade.fuse_left < grenade.fuse_time)
	_check_true("the grenade has not gone off before its fuse runs out", not grenade.exploded)
	_check("nobody is hurt yet", near.hurts, 0)

	# ...and then it does.
	grenade._physics_process(0.2)
	_check_true("the grenade explodes when the fuse runs out", grenade.exploded)
	_check("someone inside the radius dies", near.hurts, 1)
	_check("someone at the edge dies", edge.hurts, 1)
	_check("the thrower dies too", thrower.hurts, 1)
	_check("someone outside the radius survives", far.hurts, 0)

	var explosions := 0
	for child in _holder.get_children():
		if child is CPUParticles2D:
			explosions += 1
	_check("one blast spawns one explosion effect", explosions, 1)
	_check_true("the grenade removes itself", grenade.is_queued_for_deletion())

	for node in [near, edge, far, thrower]:
		node.queue_free()

# ---------------------------------------------------------------------------
# 5. Mine.
# ---------------------------------------------------------------------------

func _check_mine() -> void:
	var mine = _add(MINE_SCENE)
	mine.global_position = Vector2(4000, -4000)

	# Standing right on top of it from the very first frame: the ONLY thing
	# keeping this player alive is the arming delay.
	var victim := _make_victim(mine.global_position + Vector2(20, 0))
	await get_tree().physics_frame
	await get_tree().physics_frame

	# A dropped mine that has settled. As with the grenade, this pins the
	# position so the arming delay below can be advanced in one step without the
	# mine falling out from under the player standing on it.
	mine.sleeping = true

	_check_true("a mine in your hands is not armed", not mine.armed)
	mine._physics_process(10.0)
	_check("a mine that was never dropped never triggers", victim.hurts, 0)

	# Dropping it starts the arming delay.
	mine._on_throw()
	_check_true("dropping a mine starts it arming", mine.dropped)
	_check_true("...but it is not armed yet", not mine.armed)

	mine._physics_process(mine.arm_delay - 0.1)
	_check_true("a mine is still inert before its arming delay is up", not mine.armed)
	_check("...so you cannot suicide-place it", victim.hurts, 0)
	_check_true("...and it has not gone off", not mine.exploded)

	mine._physics_process(0.2)
	_check_true("a mine at rest still arms", mine.armed)

	# Armed, and someone is standing on it.
	mine._physics_process(0.016)
	_check("an armed mine detonates on proximity", victim.hurts, 1)
	_check_true("...and removes itself", mine.is_queued_for_deletion())

	# Out of range is out of range.
	var mine2 = _add(MINE_SCENE)
	mine2.global_position = Vector2(8000, -4000)
	var distant := _make_victim(mine2.global_position + Vector2(300, 0))
	await get_tree().physics_frame
	await get_tree().physics_frame

	mine2.sleeping = true
	mine2._on_throw()
	mine2._physics_process(mine2.arm_delay + 0.1)
	mine2._physics_process(0.016)
	_check_true("an armed mine with nobody near it waits", not mine2.exploded)
	_check("...and hurts nobody", distant.hurts, 0)

	# Picking a mine back up disarms it.
	var holder := _make_victim(Vector2(8000, -3000))
	mine2.pickup(holder)
	_check_true("picking a mine up disarms it", not mine2.armed)
	_check_true("...and forgets that it was dropped", not mine2.dropped)

	mine2.queue_free()
	victim.queue_free()
	distant.queue_free()
	holder.queue_free()

# ---------------------------------------------------------------------------
# 6. Laser.
# ---------------------------------------------------------------------------

func _check_laser() -> void:
	var laser = _add(LASER_SCENE)
	var origin := Vector2(0, 6000)
	laser.global_position = origin

	# A solid wall at +300, and a one-way platform in the way at +150. The
	# platform is a REAL body -- the second raycast below proves it -- so
	# "the beam went through it" cannot pass by accident.
	var wall := _make_static_body(origin + Vector2(300, 0), Vector2(20, 400), ENVIRONMENT_LAYER)
	var platform := _make_static_body(origin + Vector2(150, 0), Vector2(60, 12), ONE_WAY_LAYER)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_check_true("the beam is cast against solid terrain",
		(laser.get_beam_mask() & (1 << (ENVIRONMENT_LAYER - 1))) != 0)
	_check_true("the beam is cast against players",
		(laser.get_beam_mask() & (1 << (PLAYER_LAYER - 1))) != 0)
	_check_true("the beam ignores one-way platforms",
		(laser.get_beam_mask() & (1 << (ONE_WAY_LAYER - 1))) == 0)

	# Sanity: the platform really is there and really does block things that
	# collide with its layer.
	var space: PhysicsDirectSpaceState2D = laser.get_world_2d().direct_space_state
	var platform_query := PhysicsRayQueryParameters2D.create(origin, origin + Vector2(1600, 0))
	platform_query.collision_mask = 1 << (ONE_WAY_LAYER - 1)
	var platform_hit: Dictionary = space.intersect_ray(platform_query)
	_check_true("the one-way platform is a real body in the beam's path",
		not platform_hit.is_empty())
	if not platform_hit.is_empty():
		_check_near("...sitting 120px away", platform_hit["position"].x - origin.x, 120.0, 1.0)

	var clear_shot: Dictionary = laser.resolve_beam(origin, Vector2.RIGHT)
	_check_near("the beam passes through the one-way platform and stops at the wall",
		clear_shot["end"].x - origin.x, 290.0, 1.0)
	_check_true("...and finds nobody behind solid terrain",
		NodePath(clear_shot["victim"]).is_empty())

	# Someone between the platform and the wall.
	var target := _make_victim(origin + Vector2(200, 0))
	await get_tree().physics_frame
	await get_tree().physics_frame

	var kill_shot: Dictionary = laser.resolve_beam(origin, Vector2.RIGHT)
	_check("the beam finds the first player in its path", kill_shot["victim"], target.get_path())
	_check_near("...and stops at them", kill_shot["end"].x - origin.x, 184.0, 1.0)

	# Someone standing BEHIND the wall is safe: solid terrain blocks the shot.
	var sheltered := _make_victim(origin + Vector2(500, 0))
	target.get_parent().remove_child(target)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var blocked_shot: Dictionary = laser.resolve_beam(origin, Vector2.RIGHT)
	_check_true("solid terrain blocks the beam", NodePath(blocked_shot["victim"]).is_empty())
	_check("...so someone behind it is untouched", sheltered.hurts, 0)

	# The holder is standing on the barrel and must never be the victim.
	var holder := _make_victim(origin)
	laser.player = holder
	_holder.add_child(target)
	target.global_position = origin + Vector2(200, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var self_shot: Dictionary = laser.resolve_beam(origin, Vector2.RIGHT)
	_check("the shooter is not their own target", self_shot["victim"], target.get_path())

	laser.queue_free()
	wall.queue_free()
	platform.queue_free()
	target.queue_free()
	sheltered.queue_free()
	holder.queue_free()

# ---------------------------------------------------------------------------
# 7. Round teardown.
#
# Game.game_stop() frees the PLAYERS; loose pickups live under the map and are
# only destroyed when Game.reload_map() replaces the whole map node -- which
# happens on a restart but NOT when a match is abandoned to the menu. Pickups
# are therefore in the "map_object" group, which Map.map_stop() calls into.
# ---------------------------------------------------------------------------

func _check_round_teardown() -> void:
	var mine = _add(MINE_SCENE)
	_check_true("a pickup is a map object", mine.is_in_group("map_object"))
	_check_true("...so map teardown can reach it", mine.has_method("map_object_stop"))

	mine.sleeping = true
	mine._on_throw()
	mine._physics_process(mine.arm_delay + 0.1)
	_check_true("the mine is armed", mine.armed)

	mine.map_object_stop()
	_check_true("stopping the round disarms a live mine", not mine.fuse_lit)
	_check_true("...and removes it from the arena", mine.is_queued_for_deletion())

	var gun = _add(GUN_SCENE)
	_check_true("an ordinary weapon is a map object too", gun.is_in_group("map_object"))
	gun.map_object_stop()
	_check_true("...and stops simulating when the round ends", gun.sleeping)
	gun.queue_free()


# Carry tilt must pivot the weapon about its GRIP, not its own centre.
#
# An upright sword lies across a 48x68 capsule's face and pokes 2px past the
# silhouette, which is what "decentralized when held" describes; tilting it puts
# the hilt at the body edge and reads as a grip. The tilt is only correct if the
# grip offset rotates with it -- rotate the sprite alone and the weapon turns
# about its centre, carrying the grip away from the hand. Nothing errors when
# that regresses; the weapon just drifts off the character.
func _check_carry_rotation() -> void:
	var sword = _add(SWORD_SCENE)
	await get_tree().process_frame

	_check_true("the sword carries tilted", absf(sword.carry_rotation) > 0.001)

	# carry_offset() places the weapon's origin relative to the carry marker.
	# Wherever it lands, the grip must come back to the marker origin.
	var offset: Vector2 = sword.carry_offset()
	var grip_in_marker_space: Vector2 = \
		offset + sword.held_position.position.rotated(deg_to_rad(sword.carry_rotation))
	_check_true("the grip lands on the carry marker",
		grip_in_marker_space.length() < 0.01)

	# The whole point of the tilt: the weapon must actually move off the upright.
	var upright: Vector2 = -sword.held_position.position
	_check_true("tilting moves the weapon off upright",
		offset.distance_to(upright) > 1.0)

	# pickup() is what applies the tilt when a player grabs it.
	sword.pickup(null)
	_check("picking it up applies the tilt",
		snappedf(rad_to_deg(sword.rotation), 0.1),
		snappedf(sword.carry_rotation, 0.1))

	# A weapon with no tilt must be untouched by any of this.
	var gun = _add(GUN_SCENE)
	await get_tree().process_frame
	if absf(gun.carry_rotation) < 0.001:
		_check("an untilted weapon keeps the plain offset",
			gun.carry_offset(), -gun.held_position.position)

	sword.queue_free()
	gun.queue_free()
	await get_tree().process_frame


# The hand a carried weapon is held in.
#
# Cosmetic, but it fails silently in ways that read as a broken character: a
# hand left visible after a throw is a dot floating in mid-air, and a hand whose
# colour does not track the skin looks like somebody else is holding the weapon.
# Neither errors.
func _check_held_hand() -> void:
	var player = load("res://actors/Player.tscn").instantiate()
	_holder.add_child(player)
	player.player_controlled = false
	await get_tree().process_frame

	var hand: Node2D = player.get_node_or_null("HeldHand") as Node2D
	_check_true("the player has a hand node", hand != null)
	if hand == null:
		player.queue_free()
		return

	_check("empty-handed, no hand is drawn", hand.visible, false)

	# It must sit ON the grip, which is the carry marker -- a hand offset from
	# the weapon is worse than no hand at all.
	var sword = _add(SWORD_SCENE)
	await get_tree().process_frame
	player._do_pickup(sword.get_path())
	await get_tree().process_frame

	_check("holding, the hand appears", hand.visible, true)
	_check("the hand sits on the carry marker",
		hand.position, player.current_pickup_position.position)
	# In FRONT of the weapon: underneath it reads as a bead behind the handle.
	_check_true("the hand draws above the weapon",
		hand.z_index > player.current_pickup.z_index)

	# Colour is measured from the art, so it must match the skin exactly.
	player.set_player_skin(2)
	await get_tree().process_frame
	_check("the hand takes the character colour",
		hand.color, Characters.body_color(2))
	_check("...and is outlined in the measured ink", hand.ink, Characters.INK)

	player.queue_free()
	await get_tree().process_frame
