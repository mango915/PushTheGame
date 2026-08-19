class_name GameSettings
extends Resource

# Central tuning for the game: movement feel and match rules in one resource,
# so they can be changed by editing res://resources/default_game_settings.tres
# instead of hunting magic numbers across scripts.
#
# IMPORTANT: every peer in an online match must simulate with the SAME values.
# Player._physics_process replays remote players' input buffers against local
# physics, so two peers running different numbers drift apart silently, with no
# error anywhere. Game.gd ships the host's settings with _do_game_setup() and
# every peer rebuilds them before players are spawned -- see to_dict()/from_dict().

const PROJECT_GRAVITY_SETTING := "physics/2d/default_gravity"

# Every tunable, in one list. to_dict()/from_dict() walk it, so adding a field
# here is all it takes for it to be replicated to clients.
const FIELDS := [
	"speed",
	"acceleration",
	"friction",
	"sliding_friction",
	"jump_speed",
	"glide_speed",
	"terminal_velocity",
	"push_back_speed",
	"throw_velocity",
	"throw_upward_velocity",
	"throw_vector_mix",
	"throw_vector_max_length",
	"throw_torque",
	"rounds_to_win",
	"sync_delay",
	"gravity",
]

@export_group("Movement")
@export var speed: float = 350.0
@export var acceleration: float = 2000.0
@export var friction: float = 1500.0
@export var sliding_friction: float = 400.0
@export var jump_speed: float = 700.0
@export var glide_speed: float = -100.0
@export var terminal_velocity: float = 1000.0
@export var push_back_speed: float = 50.0

@export_group("Throwing")
@export var throw_velocity: float = 300.0
@export var throw_upward_velocity: float = 500.0
@export var throw_vector_mix: float = 0.5
@export var throw_vector_max_length: float = 700.0
@export var throw_torque: float = 10.0

@export_group("Match rules")
## Round wins needed to take the whole match (Main.gd).
@export var rounds_to_win: int = 5
## Physics frames between forced position syncs for the local player (Player.gd).
@export var sync_delay: int = 3
## Downward acceleration applied to players.
##
## 0 (the default) means "use the project's physics/2d/default_gravity", which
## is what Player.gd read before this resource existed -- so an untouched
## settings resource keeps the shipped feel, and the project setting stays the
## single place to change gravity globally. Any value > 0 overrides it. A
## sentinel is used rather than baking the project value into the default so
## that the .tres does not silently go stale if project.godot changes.
@export var gravity: float = 0.0

# Resolved lazily so the ProjectSettings lookup does not run every physics frame.
var _project_gravity: float = -1.0

# The gravity the game should actually apply, resolving the sentinel above.
func get_gravity() -> float:
	if gravity > 0.0:
		return gravity
	if _project_gravity < 0.0:
		_project_gravity = float(ProjectSettings.get_setting(PROJECT_GRAVITY_SETTING))
	return _project_gravity

# Resources do not survive an RPC round-trip reliably, so settings travel as a
# plain Dictionary and are rebuilt on the far side.
func to_dict() -> Dictionary:
	var data := {}
	for field in FIELDS:
		data[field] = get(field)
	return data

func apply_dict(data: Dictionary) -> void:
	for field in FIELDS:
		if data.has(field):
			set(field, data[field])
	# A new gravity value invalidates any cached project default.
	_project_gravity = -1.0

static func from_dict(data: Dictionary) -> GameSettings:
	var settings := GameSettings.new()
	settings.apply_dict(data)
	return settings

func duplicate_settings() -> GameSettings:
	return from_dict(to_dict())


#####
# Persistence
#
# The in-game Settings screen writes here, so a player can retune the game
# without opening the editor. Stored as plain text under user:// next to the
# server settings.
#####

const CONFIG_PATH := "user://settings.cfg"
const CONFIG_SECTION := "gameplay"
const DEFAULTS_PATH := "res://resources/default_game_settings.tres"

# Start from the shipped defaults, then apply whatever the player saved.
# Always returns a FRESH instance: mutating the preloaded .tres would leave the
# resource cache holding those edits for the rest of the process.
static func load_saved() -> GameSettings:
	var settings: GameSettings
	var defaults = load(DEFAULTS_PATH)
	if defaults is GameSettings:
		settings = defaults.duplicate_settings()
	else:
		settings = GameSettings.new()

	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) == OK:
		var data := {}
		for field in FIELDS:
			if config.has_section_key(CONFIG_SECTION, field):
				data[field] = config.get_value(CONFIG_SECTION, field)
		settings.apply_dict(data)

	return settings

# Writes only the gameplay section, leaving the server settings that Online.gd
# keeps in the same file untouched.
func save_to_config() -> void:
	var config := ConfigFile.new()
	config.load(CONFIG_PATH)
	for field in FIELDS:
		config.set_value(CONFIG_SECTION, field, get(field))
	config.save(CONFIG_PATH)

# Forget any saved tuning and go back to the shipped values.
static func clear_saved() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	if config.has_section(CONFIG_SECTION):
		config.erase_section(CONFIG_SECTION)
	config.save(CONFIG_PATH)

#####
# Derived values, for showing the player what a number actually does
#####

# Peak height of a jump, in pixels: v^2 / 2g.
func get_jump_height() -> float:
	var g := get_gravity()
	if g <= 0.0:
		return 0.0
	return (jump_speed * jump_speed) / (2.0 * g)

# Time from leaving the ground to landing again, in seconds: 2v / g.
func get_jump_airtime() -> float:
	var g := get_gravity()
	if g <= 0.0:
		return 0.0
	return (2.0 * jump_speed) / g

# How far a full-speed running jump carries, in pixels. This is the "jump
# length" players actually feel, and it depends on THREE settings: jump_speed
# and gravity set the airtime, and speed sets how far you travel during it.
func get_jump_distance() -> float:
	return speed * get_jump_airtime()
