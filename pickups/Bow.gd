extends Pickup

# Hold to draw, release to loose.
#
# Ported as a MECHANIC from the compa_dev branch, not as code. That branch reads
# Input directly inside _physics_process, which cannot work here: remote players
# are simulated by replaying their input buffer, so a weapon that consults the
# real keyboard fires on one machine and not the others. The draw is driven from
# Player.try_use()/try_use_release(), which come off the buffer like every other
# input, so every peer looses the arrow on the same frame.
#
# Its damage model is also dropped. compa_dev scales damage by draw force, which
# only means something with hit points; this game is one hit. So draw force buys
# REACH -- a tapped shot arcs into the floor, a full draw crosses the arena.

const ArrowScene: PackedScene = preload("res://pickups/Arrow.tscn")

# Fallbacks for a scene with no weapon_data assigned.
@export var draw_seconds: float = 0.75
@export var min_projectile_velocity: float = 260.0
@export var projectile_velocity: float = 1000.0
@export var max_ammo: int = 4

@onready var sprite: Sprite2D = $Sprite2D
@onready var arrow_position: Marker2D = $ArrowPosition
@onready var sounds = get_node_or_null("Sounds")

var ammo := 0
var drawing := false
var draw_amount := 0.0

func _ready() -> void:
	super._ready()
	ammo = max_ammo

func _apply_weapon_data() -> void:
	super._apply_weapon_data()
	if weapon_data == null:
		return
	draw_seconds = maxf(0.01, weapon_data.draw_seconds)
	min_projectile_velocity = weapon_data.min_projectile_velocity
	projectile_velocity = weapon_data.projectile_velocity
	max_ammo = weapon_data.max_ammo

#####
# Drawing
#####

func use() -> void:
	if drawing or ammo <= 0:
		return
	if not GameState.online_play:
		_do_draw()
	else:
		rpc("_do_draw")

# Broadcast rather than arbitrated: drawing has no contested outcome, and every
# peer needs the bend running locally so the shot looks the same everywhere.
@rpc("any_peer", "call_local") func _do_draw() -> void:
	drawing = true
	draw_amount = 0.0

func _process(delta: float) -> void:
	if not drawing:
		return
	draw_amount = clampf(draw_amount + delta / draw_seconds, 0.0, 1.0)
	# The limbs bend as it is pulled: the only feedback the player gets about
	# how far along the draw is.
	if sprite != null:
		sprite.scale = Vector2(1.0 - 0.22 * draw_amount, 1.0 + 0.12 * draw_amount)

func use_release() -> void:
	if not drawing:
		return
	if not GameState.online_play:
		_do_loose(draw_amount)
	else:
		rpc("_do_loose", draw_amount)

# The draw amount travels with the shot. Every peer has been counting, but they
# started on whatever frame the draw packet arrived, so the shooter's figure is
# the one that decides where the arrow goes.
@rpc("any_peer", "call_local") func _do_loose(amount: float) -> void:
	drawing = false
	draw_amount = 0.0
	if sprite != null:
		sprite.scale = Vector2.ONE

	if ammo <= 0:
		return
	ammo -= 1

	if sounds != null and sounds.has_node("Shoot"):
		sounds.play("Shoot")

	# Only the peer that owns the shooter spawns the arrow; the others would
	# each spawn their own copy of it.
	if GameState.online_play and (player == null or not player.is_multiplayer_authority()):
		return

	var speed := lerpf(min_projectile_velocity, projectile_velocity, clampf(amount, 0.0, 1.0))
	var dir := Vector2.LEFT if _facing_left() else Vector2.RIGHT
	# Angled slightly up, so even a full draw arcs rather than flying flat and
	# turning the bow into a hitscan rifle.
	dir = dir.rotated(deg_to_rad(-14.0 if not _facing_left() else 14.0))

	var arrow := ArrowScene.instantiate()
	arrow.name = Util.find_unique_name(original_parent, "Arrow-")
	original_parent.add_child(arrow)
	arrow.launch(arrow_position.global_position, dir, speed)

func _facing_left() -> bool:
	return global_scale.x < 0.0 or (player != null and player.flip_h)

# Dropping a drawn bow releases the string without firing: a shot that fires
# itself because you were disarmed is a shot nobody aimed.
func _on_throw() -> void:
	drawing = false
	draw_amount = 0.0
	if sprite != null:
		sprite.scale = Vector2.ONE
