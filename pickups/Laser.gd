extends Pickup

# Instant hitscan beam across the whole arena, with a slow recharge between
# shots. No travel time and no drop: if you can see them in a straight line,
# they are dead.
#
# --- Terrain, and what the beam goes through --------------------------------
#
# The raycast masks the "Environment" layer (1) and the "Player" layer (2), and
# deliberately NOT "OneWayPlatforms" (5, the layer maps/arena_oneway_tileset.tres
# puts its tiles on). So the beam passes straight through the thin platforms
# players jump up through, and is stopped dead by solid terrain -- which is what
# makes cover mean something.
#
# --- Why one peer resolves the shot -----------------------------------------
#
# Hitscan and replayed-input netcode do not mix. Remote players are simulated
# locally from their input buffer, so at the instant the trigger is pulled each
# peer has every OTHER player a few frames' worth of movement away from where
# their own peer has them. A beam is a zero-thickness line: that difference is
# the difference between a hit and a miss, and each peer raycasting for itself
# would produce a different answer on every screen.
#
# So the shooter's peer -- and only the shooter's peer -- casts the ray, and
# broadcasts both endpoints and the victim it found. Everyone draws the same
# beam between the same two points and kills the same player.

var LaserBeam: PackedScene = preload("res://pickups/LaserBeam.tscn")
var SparksEffect: PackedScene = preload("res://pickups/SparksEffect.tscn")

# Fallbacks for a scene with no weapon_data; laser_weapon.tres overrides them.
@export var beam_range: float = 1600.0
@export var beam_duration: float = 0.16
@export var cooldown_time: float = 2.5
@export var max_ammo: int = 4

# 1-BASED physics layers, as named in project.godot.
const ENVIRONMENT_LAYER := 1
const PLAYER_LAYER := 2

@onready var beam_origin: Marker2D = $BeamOrigin
@onready var cooldown_timer: Timer = $CooldownTimer
@onready var sounds := $Sounds

var allow_shoot := true

# Filled from max_ammo in _ready(), i.e. after weapon_data has been applied.
var ammo := 0

func _ready() -> void:
	super._ready()

	ammo = max_ammo
	cooldown_timer.wait_time = cooldown_time

func _apply_weapon_data() -> void:
	super._apply_weapon_data()

	if weapon_data == null:
		return

	if weapon_data.beam_range > 0.0:
		beam_range = weapon_data.beam_range
	if weapon_data.beam_duration > 0.0:
		beam_duration = weapon_data.beam_duration
	if weapon_data.cooldown_time > 0.0:
		cooldown_time = weapon_data.cooldown_time
	if weapon_data.max_ammo > 0:
		max_ammo = weapon_data.max_ammo

# The physics mask the beam is cast against: solid terrain and players, never
# one-way platforms.
func get_beam_mask() -> int:
	return (1 << (ENVIRONMENT_LAYER - 1)) | (1 << (PLAYER_LAYER - 1))

func use() -> void:
	if not allow_shoot:
		return

	allow_shoot = false
	cooldown_timer.start()

	# In an online match use() only runs on the peer holding this weapon
	# (actors/player-states/Idle.gd refuses to act for a remote player), but the
	# check is spelled out anyway so the rule is where the raycast is, and not
	# three files away.
	if GameState.online_play and (player == null or not player.is_multiplayer_authority()):
		return

	var from: Vector2 = beam_origin.global_position
	var shot := resolve_beam(from, Vector2.RIGHT.rotated(global_rotation))

	if not GameState.online_play:
		_do_beam(from, shot["end"], shot["victim"])
	else:
		rpc("_do_beam", from, shot["end"], shot["victim"])

# Casts the beam and reports where it stopped and who it caught.
#
# The holder is excluded from the cast: they are standing on top of the barrel,
# so an unexcluded ray would find them first and the weapon would only ever
# shoot its own user. This is the hitscan version of Player.hurt()'s refusal to
# damage you with a weapon you are holding.
func resolve_beam(from: Vector2, direction: Vector2) -> Dictionary:
	var result := {
		"end": from + (direction * beam_range),
		"victim": NodePath(),
	}

	var world := get_world_2d()
	if world == null:
		return result

	var query := PhysicsRayQueryParameters2D.create(from, result["end"])
	query.collision_mask = get_beam_mask()
	query.collide_with_bodies = true
	query.collide_with_areas = false
	if player != null and is_instance_valid(player):
		query.exclude = [player.get_rid()]

	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return result

	result["end"] = hit["position"]

	var body = hit.get("collider")
	if body != null and is_instance_valid(body) and body.has_method("hurt"):
		# Absolute path, so it resolves on every peer -- the same thing
		# Player._try_pickup() broadcasts when the host arbitrates a pickup.
		result["victim"] = body.get_path()

	return result

@rpc("any_peer", "call_local") func _do_beam(from: Vector2, to: Vector2, victim_path: NodePath) -> void:
	if ammo <= 0:
		var sparks = SparksEffect.instantiate()
		beam_origin.add_child(sparks)
		sounds.play("Empty")
		return

	ammo -= 1
	sounds.play("Shoot")

	var beam = LaserBeam.instantiate()
	var beam_parent: Node = original_parent
	if beam_parent == null or not is_instance_valid(beam_parent):
		beam_parent = get_parent()
	beam_parent.add_child(beam)
	beam.show_beam(from, to, beam_duration)

	if victim_path.is_empty():
		return

	var victim = get_node_or_null(victim_path)
	if victim == null or not is_instance_valid(victim):
		return
	if not victim.has_method("hurt"):
		return
	# Who died was decided by the shooter's peer; applying the death is still
	# the victim peer's job, exactly as in components/Hitbox.gd.
	if GameState.online_play and not victim.is_multiplayer_authority():
		return

	# The barrel marker, NOT the beam: LaserBeam goes top_level with an identity
	# transform so its own global_position is the world origin, and Player.hurt()
	# reads the source node's position to work out which way to shove the victim.
	# From the barrel, that shove points away from the shooter.
	victim.hurt(beam_origin)

func _on_CooldownTimer_timeout() -> void:
	allow_shoot = true
