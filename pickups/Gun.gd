extends Pickup

var DisintegrateEffect: PackedScene = preload("res://pickups/DisintegrateEffect.tscn")
var SparksEffect: PackedScene = preload("res://pickups/SparksEffect.tscn")

# Fallback tuning, used verbatim when the scene has no `weapon_data` assigned.
# When one is assigned (see resources/gun_weapon.tres) these are overwritten in
# _apply_weapon_data() before anything reads them.
@export var projectile_scene: PackedScene = preload("res://pickups/Projectile.tscn")
@export var projectile_velocity : float = 1200.0
@export var projectile_range : float = 400.0
@export var cooldown_time : float = 0.3
@export var max_ammo : int = 3

# --- Spread / knockback -----------------------------------------------------
# A one-pellet, no-spread, no-knockback, no-recoil gun is exactly the gun this
# script has always been, so these defaults leave res://pickups/Gun.tscn alone.
# The shotgun (res://pickups/Shotgun.gd) is this same firing flow with the
# numbers turned up -- see res://resources/shotgun_weapon.tres.

## Projectiles per shot.
@export var pellet_count : int = 1
## Total width of the fan the pellets are spread across, in degrees.
@export var spread_degrees : float = 0.0
## Extra shove handed to each projectile's Hitbox (components/Hitbox.gd).
@export var knockback : float = 0.0
@export var knockback_up : float = 0.0
## Backwards shove applied to the shooter when the weapon fires.
@export var recoil : float = 0.0

@onready var projectile_position := $ProjectilePosition
@onready var sparks_position := $SparksPosition
@onready var dud_detector := $DudDetector
@onready var animation_player := $AnimationPlayer
@onready var cooldown_timer := $CooldownTimer
@onready var sounds := $Sounds

var allow_shoot := true

# Filled from max_ammo in _ready(), i.e. after weapon_data has been applied --
# an @onready initialiser would run too early and capture the fallback value.
var ammo := 0

var use_by_player: Node = null

func _ready() -> void:
	# Applies weapon_data (Pickup._ready -> _apply_weapon_data below).
	super._ready()

	ammo = max_ammo
	cooldown_timer.wait_time = cooldown_time

func _apply_weapon_data() -> void:
	super._apply_weapon_data()

	if weapon_data == null:
		return

	# A resource that leaves projectile_scene empty keeps this gun's own scene.
	if weapon_data.projectile_scene != null:
		projectile_scene = weapon_data.projectile_scene

	projectile_velocity = weapon_data.projectile_velocity
	projectile_range = weapon_data.projectile_range
	cooldown_time = weapon_data.cooldown_time
	max_ammo = weapon_data.max_ammo

	# 0 means "not specified by this resource" -- see the note at the bottom of
	# WeaponData.gd. gun_weapon.tres predates all four fields.
	if weapon_data.pellet_count > 0:
		pellet_count = weapon_data.pellet_count
	if weapon_data.spread_degrees > 0.0:
		spread_degrees = weapon_data.spread_degrees
	if weapon_data.knockback > 0.0:
		knockback = weapon_data.knockback
	if weapon_data.knockback_up > 0.0:
		knockback_up = weapon_data.knockback_up
	if weapon_data.recoil > 0.0:
		recoil = weapon_data.recoil

func use() -> void:
	if not allow_shoot:
		return

	allow_shoot = false
	cooldown_timer.start()

	if ammo > 0:
		if not GameState.online_play:
			_start_use()
		else:
			rpc("_start_use")
	else:
		# Dry fire never goes through _start_use(), so assign the user here;
		# otherwise _fire_projectile() dereferences a null use_by_player.
		use_by_player = player
		_fire_projectile()

@rpc("any_peer", "call_local") func _start_use() -> void:
	# Account for a player throwing the gun before it actually fires.
	use_by_player = player

	animation_player.play("Shoot")

# The angles, relative to the barrel, of each pellet in one shot.
#
# Deterministic on purpose. Only the shooter's peer reaches _fire_projectile()
# (see the authority check there) and it broadcasts the resulting vectors, so
# randomness would still be consistent -- but a fixed fan also means the spread
# is the same every time the player pulls the trigger, which is what makes a
# short-range weapon learnable rather than a lottery.
func get_pellet_angles() -> PackedFloat32Array:
	var pellets := maxi(1, pellet_count)
	var angles := PackedFloat32Array()

	if pellets == 1 or spread_degrees <= 0.0:
		for i in range(pellets):
			angles.append(0.0)
		return angles

	var spread := deg_to_rad(spread_degrees)
	for i in range(pellets):
		# -0.5 .. +0.5 across the fan, so the outermost pellets sit exactly
		# spread_degrees apart and the pattern is centred on the barrel.
		angles.append(spread * ((float(i) / float(pellets - 1)) - 0.5))
	return angles

func _fire_projectile() -> void:
	if GameState.online_play and (use_by_player == null or not use_by_player.is_multiplayer_authority()):
		return

	var projectile_dud: bool = dud_detector.get_overlapping_bodies().size() > 0
	var angles := get_pellet_angles()

	# One unique base name for the shot; the pellets are numbered off it. Asking
	# Util.find_unique_name() once per pellet could hand out the same name twice,
	# because none of them are in the tree yet for it to check against.
	var base_name: String = Util.find_unique_name(original_parent, 'Projectile-')
	var projectile_names := PackedStringArray()
	var projectile_vectors := PackedVector2Array()
	for i in range(angles.size()):
		projectile_names.append(base_name if angles.size() == 1 else "%s-%d" % [base_name, i])
		projectile_vectors.append((Vector2.RIGHT * projectile_velocity).rotated(global_rotation + angles[i]))

	if not GameState.online_play:
		_do_fire_projectile(projectile_names, projectile_position.global_position, projectile_vectors, projectile_range, projectile_dud)
	else:
		rpc("_do_fire_projectile", projectile_names, projectile_position.global_position, projectile_vectors, projectile_range, projectile_dud)

@rpc("any_peer", "call_local") func _do_fire_projectile(_projectile_names: PackedStringArray, _projectile_position: Vector2, _projectile_vectors: PackedVector2Array, _projectile_range: float, _projectile_dud: bool) -> void:
	var projectile_parent = original_parent

	if ammo <= 0:
		var sparks = SparksEffect.instantiate()
		sparks_position.add_child(sparks)
		sounds.play("Empty")
	else:
		ammo -= 1

		for i in range(_projectile_vectors.size()):
			var projectile = projectile_scene.instantiate()
			projectile.name = _projectile_names[i] if i < _projectile_names.size() else "%s-%d" % [_projectile_names[0], i]
			projectile_parent.add_child(projectile)

			projectile.shoot(_projectile_position, _projectile_vectors[i], _projectile_range, _projectile_dud, knockback, knockback_up)

		sounds.play("Shoot")
		_apply_recoil(_projectile_vectors)

# Shoves the shooter backwards. Runs inside the call_local RPC above, so every
# peer applies the identical impulse to its own copy of the shooter and the
# replayed-input simulation stays in step.
func _apply_recoil(_projectile_vectors: PackedVector2Array) -> void:
	if recoil <= 0.0:
		return
	if use_by_player == null or not is_instance_valid(use_by_player):
		return
	if _projectile_vectors.is_empty():
		return

	var aim := _projectile_vectors[0].normalized()
	if aim == Vector2.ZERO:
		return
	# Horizontal only: a vertical kick would fight the jump/fall states.
	use_by_player.set("vector", use_by_player.get("vector") + Vector2(-aim.x * recoil, 0.0))

func _on_throw_finished() -> void:
	# _do_physics_finished() is an @rpc(..., "call_local") method, so this
	# already runs on every peer - only the authority may re-broadcast.
	if not GameState.online_play or is_multiplayer_authority():
		if ammo <= 0:
			if not GameState.online_play:
				_disintegrate()
			else:
				rpc("_disintegrate")

@rpc("any_peer", "call_local") func _disintegrate() -> void:
	var parent = get_parent();
	if parent:
		var effect = DisintegrateEffect.instantiate()
		parent.add_child(effect)
		effect.global_position = global_position + Vector2(0, 10)

	queue_free()

func _on_CooldownTimer_timeout() -> void:
	allow_shoot = true

func _on_AnimationPlayer_animation_finished(anim_name: String) -> void:
	if anim_name == 'Shoot':
		animation_player.play("Idle")
