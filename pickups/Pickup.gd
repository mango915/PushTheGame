extends CharacterBody2D
class_name Pickup

@onready var held_position: Marker2D = $HeldPosition

# Carry tilt in degrees; see WeaponData.carry_rotation. Lives here as well so a
# pickup with no WeaponData resource still has a usable default.
@export_range(-180.0, 180.0, 1.0) var carry_rotation: float = 0.0

# Where this weapon sits once it is in a hand.
#
# The weapon is parented to the carry marker and offset so its HeldPosition --
# the grip -- lands on the marker origin. Tilting it therefore has to rotate
# that offset too: rotate the sprite alone and the weapon pivots about its own
# centre, swinging the grip away from the hand instead of turning in it.
func carry_offset() -> Vector2:
	return -held_position.position.rotated(deg_to_rad(carry_rotation))
@onready var original_parent: Node2D = get_parent()
@onready var gravity: float = float(ProjectSettings.get_setting("physics/2d/default_gravity"))
@onready var linear_damp: float = float(ProjectSettings.get_setting("physics/2d/default_linear_damp"))
@onready var angular_damp: float = float(ProjectSettings.get_setting("physics/2d/default_angular_damp"))

enum PickupPosition {
	FRONT,
	BACK,
}

@export var pickup_position : PickupPosition = PickupPosition.FRONT

# Optional per-weapon tuning. When left unassigned every value below keeps the
# default declared in this script (or in the subclass), so a weapon scene built
# before WeaponData existed behaves exactly as it always did.
@export var weapon_data: WeaponData = null

# --- Thrown-weapon damage ---------------------------------------------------
#
# A weapon in flight is a weapon: an empty gun still kills, and disarming
# someone by throwing something at them hands them your ammo. The numbers live
# on WeaponData (see throw_damage_speed / throw_self_immunity) so a heavy sword
# can stay lethal much later into its arc than a light gun; the values here are
# the fallback for a scene with no resource assigned, and each weapon scene
# overrides them in the inspector.
#
# 0 disables thrown damage for this weapon entirely (the explosives use it --
# they have their own, much louder, way of killing you).
@export var throw_damage_speed: float = 0.0

# Seconds after release during which the thrower is immune to their own throw.
# Player.hurt() already refuses damage from a weapon the victim is HOLDING;
# once thrown it is no longer held, so the same protection has to be spelled
# out here or every throw would kill the thrower on the release frame.
@export var throw_self_immunity: float = 0.35

# The 1-BASED physics layer the players are on ("Player" in project.godot).
# Matches the collision_mask of 2 that every Hitbox in the game uses.
const PLAYER_COLLISION_LAYER := 2

enum PickupState {
	FREE = 0,
	PICKED_UP,
	WORN,
	THROWING,
	THROWN,
}

# Minimum thresholds in order to sleep physics on this body.
const MIN_LINEAR_VELOCITY := 10.0
const MIN_ANGULAR_VELOCITY := 10.0

var player: Node2D
var pickup_state: int = PickupState.FREE
var throw_position := Vector2.ZERO

var sleeping := false
var linear_velocity := Vector2.ZERO
var angular_velocity := 0.0
var bounce := 0.1

# Who let go of us, and for how much longer they are safe from it.
var thrown_by: Node2D = null
var throw_immunity_left := 0.0

# Built in code from this pickup's own collision shapes, so that every weapon
# scene gets thrown damage without each of them having to gain a hitbox node.
# Null when throw_damage_speed is 0.
var thrown_hitbox: Area2D = null

signal picked_up()

func _ready():
	_apply_weapon_data()
	_build_thrown_hitbox()

# Copy the shared tunables out of weapon_data. Subclasses override this to pull
# their own fields and must call super() first. Called from _ready(), so a
# subclass that defines its own _ready() has to call super._ready().
func _apply_weapon_data() -> void:
	if weapon_data == null:
		return

	pickup_position = weapon_data.pickup_position as PickupPosition
	bounce = weapon_data.bounce
	carry_rotation = weapon_data.carry_rotation

	# 0 means "the resource does not care", so the scene's own value survives.
	# See the note at the bottom of WeaponData.gd: gun_weapon.tres and
	# sword_weapon.tres predate these fields and serialize them as 0.
	if weapon_data.throw_damage_speed > 0.0:
		throw_damage_speed = weapon_data.throw_damage_speed
	if weapon_data.throw_self_immunity > 0.0:
		throw_self_immunity = weapon_data.throw_self_immunity

func can_pickup() -> bool:
	return pickup_state == PickupState.FREE or pickup_state == PickupState.THROWN

func pickup(_player: Node2D) -> void:
	pickup_state = PickupState.PICKED_UP
	player = _player
	rotation = deg_to_rad(carry_rotation)
	sleeping = true
	emit_signal("picked_up")

func _on_throw() -> void:
	# This allows the pickup to do something special just before it's thrown.
	pass

func _on_throw_finished() -> void:
	# This allows the pickup to do something special once its stopped moving.
	pass

func throw(_throw_position: Vector2, _throw_vector: Vector2, _throw_torque: float) -> void:
	_on_throw()

	pickup_state = PickupState.THROWING
	# Captured BEFORE player is cleared: this is who must not be killed by their
	# own release. Player.hurt() covers a weapon still in the victim's hands;
	# from here on the weapon is nobody's, so the grace period below is the only
	# thing between a thrower and their own sword.
	thrown_by = player
	throw_immunity_left = throw_self_immunity
	player = null

	throw_position = _throw_position
	linear_velocity = _throw_vector
	angular_velocity = _throw_torque

	sleeping = false

func use() -> void:
	# Implement this in child classes.
	pass

# Called when the use button is RELEASED, for weapons that charge while held.
# Instant weapons ignore it.
func use_release() -> void:
	pass

func _physics_process(delta: float) -> void:
	# Ticked before the early returns, so a pickup that is caught mid-flight (or
	# put to sleep) does not freeze its thrower's grace period and hand it back
	# to them on the next throw.
	if throw_immunity_left > 0.0:
		throw_immunity_left = maxf(0.0, throw_immunity_left - delta)

	if sleeping:
		return
	if pickup_state == PickupState.PICKED_UP or pickup_state == PickupState.WORN:
		return

	if pickup_state == PickupState.THROWING:
		global_transform = Transform2D(0.0, throw_position)
		pickup_state = PickupState.THROWN

	# Apply gravity.
	linear_velocity += (Vector2.DOWN * gravity * delta)

	# Apply linear damp.
	var ld := 1.0 - (linear_damp * delta)
	if ld < 0:
		ld = 0.0
	linear_velocity *= ld

	# Apply angular damp.
	var ad := 1.0 - (angular_damp * delta)
	if ad < 0:
		ad = 0.0
	angular_velocity *= ad

	# Rotate/move object and detect collisions.
	global_rotation += (angular_velocity * delta)
	var collision: KinematicCollision2D = move_and_collide(linear_velocity * delta)

	# Bounce the object if it collides.
	if collision:
		# REFLECT the velocity about the surface normal. It used to be set to the
		# normal itself times the speed, which is not a bounce but a redirect:
		# every thrown weapon that touched the floor shot straight up regardless
		# of which way it had been travelling, which is what made thrown swords
		# and grenades behave so strangely.
		var normal := collision.get_normal()
		linear_velocity = linear_velocity.bounce(normal) * bounce
		# Spin scrubs off on impact too, rather than continuing untouched.
		angular_velocity *= bounce
		move_and_collide(normal * collision.get_remainder().length())

	# Sleep the object if it gets below certain linear/angular velocity thresholds.
	if not GameState.online_play or is_multiplayer_authority():
		# abs() matters: angular_velocity is signed, so a counter-clockwise spin
		# would otherwise satisfy this threshold instantly and put the pickup to
		# sleep while it is still spinning fast. Latent today only because every
		# throw currently uses a positive torque.
		if linear_velocity.length() < MIN_LINEAR_VELOCITY and abs(angular_velocity) < MIN_ANGULAR_VELOCITY:
			if GameState.online_play:
				rpc('_do_physics_finished', global_transform)
			else:
				_do_physics_finished(global_transform)

@rpc("any_peer", "call_local") func _do_physics_finished(_remote_transform = null) -> void:
	if _remote_transform:
		global_transform = _remote_transform

	sleeping = true
	if pickup_state == PickupState.THROWN:
		_on_throw_finished()
		pickup_state = PickupState.FREE

# ---------------------------------------------------------------------------
# Thrown-weapon damage
#
# The pickup body itself is on the "Pickup" layer and masks only Environment +
# OneWayPlatforms (see Pickup.tscn), so it flies straight through players and
# must not stop doing so -- a thrown weapon that bounced off people would be a
# different game. Detection therefore goes through a separate Area2D built here
# from this pickup's own collision shapes, so every weapon scene gets thrown
# damage without any of them having to gain a hitbox node by hand.
#
# It deliberately does NOT reuse components/Hitbox.gd: a Hitbox hurts on contact
# unconditionally, and a thrown weapon must only hurt while it is actually
# travelling fast enough.
# ---------------------------------------------------------------------------

func _build_thrown_hitbox() -> void:
	if throw_damage_speed <= 0.0:
		return

	var area := Area2D.new()
	area.name = "ThrownHitbox"
	# Detect players; be invisible to everything that scans for areas.
	area.collision_layer = 0
	area.collision_mask = 0
	area.set_collision_mask_value(PLAYER_COLLISION_LAYER, true)
	area.monitorable = false

	# Only DIRECT children: the Sword's own Hitbox is a separate Area2D with its
	# own polygon, and copying that here would make a thrown sword lethal over
	# its swing arc rather than its blade.
	var shapes := 0
	for child in get_children():
		if child is CollisionShape2D:
			var copy := CollisionShape2D.new()
			copy.shape = child.shape
			copy.transform = child.transform
			copy.disabled = child.disabled
			area.add_child(copy)
			shapes += 1
		elif child is CollisionPolygon2D:
			var poly := CollisionPolygon2D.new()
			poly.polygon = child.polygon
			poly.transform = child.transform
			poly.disabled = child.disabled
			area.add_child(poly)
			shapes += 1

	if shapes == 0:
		# Nothing to detect with; a weapon scene with no collision shape cannot
		# be thrown at anyone in the first place.
		area.free()
		return

	add_child(area)
	area.body_entered.connect(_on_thrown_hitbox_body_entered)
	thrown_hitbox = area

# True while this pickup is a weapon rather than scenery: in flight, awake, and
# still moving fast enough to hurt. Everything that stops being true here stops
# the kill, which is what keeps a thrown weapon lying on the floor harmless.
func is_thrown_lethal() -> bool:
	if throw_damage_speed <= 0.0:
		return false
	if sleeping:
		return false
	if pickup_state != PickupState.THROWN:
		return false
	return linear_velocity.length() >= throw_damage_speed

func _on_thrown_hitbox_body_entered(body: Node) -> void:
	if not is_thrown_lethal():
		return
	if not body.has_method("hurt"):
		return
	if body == thrown_by and throw_immunity_left > 0.0:
		return

	# Same gate as components/Hitbox.gd: remote players are simulated locally
	# from a replayed input buffer, so every peer sees this contact, but only
	# the peer that owns the victim may act on it. It then syncs the resulting
	# Hurt state to everyone else the ordinary way.
	if GameState.online_play and not body.is_multiplayer_authority():
		return

	# Passing the hitbox (not `self`) keeps Player.hurt()'s "do not cut yourself
	# with your own sword" test working: it compares current_pickup against
	# node.get_parent(), which is this pickup.
	body.hurt(thrown_hitbox)

# ---------------------------------------------------------------------------
# Round teardown
#
# Pickup.tscn is in the "map_object" group, so Map.map_stop() reaches every
# loose weapon in the arena. Game.game_stop() only frees the PLAYERS; loose
# pickups live under the map and survive until Game.reload_map() replaces the
# whole map node -- which happens on a restart, but NOT when a match is
# abandoned to the menu. Without these hooks a live mine or a burning grenade
# would keep counting down on a map nobody is playing any more.
# ---------------------------------------------------------------------------

func map_object_start() -> void:
	pass

func map_object_stop() -> void:
	# Stop simulating. Subclasses with a timer of their own override this and
	# call super() -- see Explosive.gd.
	sleeping = true

# Takes this pickup out of its holder's hands, leaving Player.current_pickup in
# a sane state. Used by anything that can destroy itself while being carried
# (an explosive that cooks too long), because simply queue_free()-ing would
# leave the player holding a freed node.
func release_from_holder() -> void:
	if player == null or not is_instance_valid(player):
		return
	var holder = player
	if holder.get("current_pickup") == self:
		# A plain local call, so Player._do_throw()'s sender check passes.
		holder._do_throw()
