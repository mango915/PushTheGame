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
