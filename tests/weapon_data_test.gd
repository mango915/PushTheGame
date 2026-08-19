extends Node

# Guards the data-driven weapon setup.
#
# Weapon tuning used to live as @export defaults inside Gun.gd/Sword.gd; it now
# lives in resources/*.tres, which the weapon scenes reference. Two things can
# silently go wrong with that arrangement:
#   - a retune of a .tres (or a lost value while editing it in the inspector)
#     changes how a weapon plays with nothing in the code diff to show it;
#   - the scene stops applying the resource at all -- which is invisible,
#     because the script's fallback defaults happen to be the same numbers.
# So this checks both the shipped resources and a live instance of each scene.

var _failures := 0

# Pickup's `original_parent` is typed Node2D, so instances have to be parented
# to a Node2D exactly as they are in a map -- not straight onto this test root.
var _holder := Node2D.new()

const GUN_SCENE := preload("res://pickups/Gun.tscn")
const SWORD_SCENE := preload("res://pickups/Sword.tscn")

const GUN_DATA_PATH := "res://resources/gun_weapon.tres"
const SWORD_DATA_PATH := "res://resources/sword_weapon.tres"

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[weapon] OK: %s" % label)
	else:
		_failures += 1
		print("[weapon] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _ready() -> void:
	print("[weapon] starting")

	add_child(_holder)

	_check_gun_resource()
	_check_sword_resource()
	_check_instances()
	_check_fallback()

	print("[weapon] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

# The shipped values. These are the numbers the game has always played with;
# a change here should be a deliberate retune, not a side effect.
func _check_gun_resource() -> void:
	var data = load(GUN_DATA_PATH)
	_check_true("gun resource loads", data != null)
	if data == null:
		return

	_check_true("gun resource is a WeaponData", data is WeaponData)
	_check("gun projectile_velocity", data.projectile_velocity, 1200.0)
	_check("gun projectile_range", data.projectile_range, 400.0)
	_check("gun cooldown_time", data.cooldown_time, 0.3)
	_check("gun max_ammo", data.max_ammo, 3)
	_check("gun bounce", data.bounce, 0.1)
	_check("gun is carried in front", data.pickup_position, Pickup.PickupPosition.FRONT)
	_check_true("gun ships a projectile scene", data.projectile_scene != null)

func _check_sword_resource() -> void:
	var data = load(SWORD_DATA_PATH)
	_check_true("sword resource loads", data != null)
	if data == null:
		return

	_check_true("sword resource is a WeaponData", data is WeaponData)
	_check("sword is carried on the back", data.pickup_position, Pickup.PickupPosition.BACK)
	_check("sword bounce", data.bounce, 0.1)

# Instantiating the real scenes proves the resource is actually wired up and
# applied by _ready(), not just sitting on disk.
func _check_instances() -> void:
	var gun = GUN_SCENE.instantiate()
	_holder.add_child(gun)

	_check_true("gun scene carries its weapon_data", gun.weapon_data != null)
	_check("gun instance max_ammo", gun.max_ammo, 3)
	_check("gun instance cooldown_time", gun.cooldown_time, 0.3)
	_check("gun instance projectile_velocity", gun.projectile_velocity, 1200.0)
	_check("gun instance projectile_range", gun.projectile_range, 400.0)
	# ammo is derived from max_ammo *after* the resource is applied.
	_check("gun starts loaded", gun.ammo, 3)
	_check("gun cooldown timer uses cooldown_time", gun.get_node("CooldownTimer").wait_time, 0.3)
	_check("gun instance pickup_position", gun.pickup_position, Pickup.PickupPosition.FRONT)
	gun.queue_free()

	var sword = SWORD_SCENE.instantiate()
	_holder.add_child(sword)

	_check_true("sword scene carries its weapon_data", sword.weapon_data != null)
	_check("sword instance pickup_position", sword.pickup_position, Pickup.PickupPosition.BACK)
	_check("sword instance bounce", sword.bounce, 0.1)
	sword.queue_free()

# A weapon scene with no resource assigned must keep behaving exactly as it did
# before WeaponData existed, so that adding the field broke nothing.
func _check_fallback() -> void:
	var gun = GUN_SCENE.instantiate()
	gun.weapon_data = null
	_holder.add_child(gun)

	_check("gun falls back to its own max_ammo", gun.max_ammo, 3)
	_check("gun falls back to its own cooldown_time", gun.cooldown_time, 0.3)
	_check("gun falls back to its own projectile_velocity", gun.projectile_velocity, 1200.0)
	_check("gun falls back to its own bounce", gun.bounce, 0.1)
	_check_true("gun falls back to its own projectile scene", gun.projectile_scene != null)
	gun.queue_free()
