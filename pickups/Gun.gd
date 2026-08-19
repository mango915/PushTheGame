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

func _fire_projectile() -> void:
	if GameState.online_play and (use_by_player == null or not use_by_player.is_multiplayer_authority()):
		return

	var projectile_name = Util.find_unique_name(original_parent, 'Projectile-')
	var projectile_vector: Vector2 = (Vector2.RIGHT * projectile_velocity).rotated(global_rotation)
	var projectile_dud: bool = dud_detector.get_overlapping_bodies().size() > 0

	if not GameState.online_play:
		_do_fire_projectile(projectile_name, projectile_position.global_position, projectile_vector, projectile_range, projectile_dud)
	else:
		rpc("_do_fire_projectile", projectile_name, projectile_position.global_position, projectile_vector, projectile_range, projectile_dud)

@rpc("any_peer", "call_local") func _do_fire_projectile(_projectile_name: String, _projectile_position: Vector2, _projectile_vector: Vector2, _projectile_range: float, _projectile_dud: bool) -> void:
	var projectile_parent = original_parent

	if ammo <= 0:
		var sparks = SparksEffect.instantiate()
		sparks_position.add_child(sparks)
		sounds.play("Empty")
	else:
		ammo -= 1

		var projectile = projectile_scene.instantiate()
		projectile.name = _projectile_name
		projectile_parent.add_child(projectile)

		projectile.shoot(_projectile_position, _projectile_vector, _projectile_range, _projectile_dud)
		sounds.play("Shoot")

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
