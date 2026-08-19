extends CharacterBody2D

# A dead player's body, flung by whatever killed them.
#
# PURELY COSMETIC, AND DELIBERATELY LOCAL.
# ----------------------------------------
# Player._explode_and_free() spawns one of these on every peer, from inside the
# path that already runs everywhere (the `_do_die()` RPC is "call_local", and
# force_remove() is called locally by each peer). The corpse therefore needs no
# networking of its own: it never RPCs, never claims authority, and two peers
# disagreeing about exactly where it came to rest is not a desync because
# nothing about the match reads it.
#
# For the same reason it must be impossible to interact with:
#   * collision_layer is 0, so no Area2D (hitboxes, pickup areas, effect zones)
#     and no other body can ever see it. It only *reads* the terrain layers
#     through its collision_mask, which is what lets it bounce off the map.
#   * it has no hurt(), no can_pickup() and -- most importantly -- no
#     pickup_or_throw(), which is the duck-typed test Camera.gd and the game
#     logic use to tell a real player from the other junk parented into the
#     Players container. See _is_not_a_player() in tests/ragdoll_test.gd.
#
# The physics are hand-rolled in the same style as pickups/Pickup.gd (gravity,
# damping, move_and_collide, bounce) rather than using a RigidBody2D, so the
# tumble matches the feel of a thrown weapon and stays fully deterministic.

# Nodes look this up to identify a corpse without depending on the script.
const GROUP := "corpses"

# How many corpses may exist at once. A long round with several deaths would
# otherwise litter the arena. The oldest is removed to make room.
const MAX_CORPSES := 6

# Seconds before the body disappears, and how much of that tail is spent fading.
const LIFETIME := 7.0
const FADE_TIME := 1.5

# Fraction of the impact speed kept when bouncing off terrain, and of the
# tangential speed kept when scraping along it.
const BOUNCE := 0.35
const SCRAPE := 0.6

# Below these the body is considered to have come to rest (px/s, rad/s).
const REST_SPEED := 25.0
const REST_SPIN := 1.0

# Spin is derived from the horizontal launch speed, then clamped so a shotgun
# blast does not turn the whale into a blur.
const SPIN_PER_SPEED := 0.012
const MAX_SPIN := 9.0

# Gib tint per character, in the order of Characters.TEXTURES.
const GIB_COLORS := [
	Color(1.0, 0.55, 0.25),   # orange
	Color(0.45, 0.85, 0.4),   # green
	Color(0.4, 0.7, 1.0),     # blue
	Color(0.75, 0.5, 1.0),    # purple
]

# The Dead animation in Player.tscn runs frames 98..101; 101 is the final,
# fully limp pose, and is what Corpse.tscn shows. FinSprite always shows the
# body frame plus one row (Player._on_BodySprite_frame_changed uses the same +7).
const DEAD_FRAME := 101
const FIN_FRAME_OFFSET := 7

@onready var body_sprite: Sprite2D = $BodySprite
@onready var fin_sprite: Sprite2D = $FinSprite
@onready var gibs: CPUParticles2D = $Gibs

@onready var gravity: float = float(ProjectSettings.get_setting("physics/2d/default_gravity"))
@onready var linear_damp: float = float(ProjectSettings.get_setting("physics/2d/default_linear_damp"))
@onready var angular_damp: float = float(ProjectSettings.get_setting("physics/2d/default_angular_damp"))

# Which entry of Characters.TEXTURES this body wore in life. -1 until setup().
var character_index: int = -1

var linear_velocity := Vector2.ZERO
var angular_velocity := 0.0

# Overridable so a test does not have to sit through the full LIFETIME.
var lifetime: float = LIFETIME

var age: float = 0.0
var resting := false

# Where the body settles to once it stops moving: the nearest "flat" angle, so
# it ends up lying on its belly or its back rather than frozen mid-tumble.
var _rest_rotation := 0.0

func _ready() -> void:
	add_to_group(GROUP)
	# Set here as well as in Corpse.tscn so the two frames cannot drift apart:
	# the fin sheet lives exactly one row below the body on the same texture.
	body_sprite.frame = DEAD_FRAME
	fin_sprite.frame = DEAD_FRAME + FIN_FRAME_OFFSET
	_enforce_cap()

# Called by Player._spawn_corpse() immediately after add_child().
#
# `inherited` is the velocity the player had when they died and `impulse` is the
# kick from whatever killed them (see Player.CORPSE_IMPULSE_SCALE), so a quiet
# death simply drops the body while a hit throws it away from the attacker.
func setup(index: int, inherited: Vector2, impulse: Vector2, flipped: bool) -> void:
	character_index = Characters.clamp_index(index)

	var sheet: Texture2D = load(Characters.TEXTURES[character_index])
	if sheet != null:
		body_sprite.texture = sheet
		fin_sprite.texture = sheet
	body_sprite.flip_h = flipped
	fin_sprite.flip_h = flipped

	linear_velocity = inherited + impulse
	angular_velocity = clamp(
		linear_velocity.x * SPIN_PER_SPEED, -MAX_SPIN, MAX_SPIN)
	# A body flung straight up with no sideways push should still turn over.
	if absf(angular_velocity) < 1.0:
		angular_velocity = 1.0 if flipped else -1.0

	_scatter_gibs()

# Which character this was, for anything that wants to show it.
func get_character_name() -> String:
	return Characters.character_name(character_index)

# The gibs are a child of the corpse rather than a sibling on purpose: the
# Players container is scanned for direct CPUParticles2D children (the death
# explosion), and a second one there would look like the double-explosion bug
# that tests/smoke_test.gd and tests/ragdoll_test.gd guard against.
func _scatter_gibs() -> void:
	if gibs == null:
		return
	# Tint them like the whale they came off, so you can see who burst.
	gibs.color = GIB_COLORS[character_index % GIB_COLORS.size()]
	gibs.emitting = true

func _physics_process(delta: float) -> void:
	age += delta

	# Fade the tail end of the lifetime, then go away.
	if age >= lifetime:
		queue_free()
		return
	var remaining := lifetime - age
	if remaining < FADE_TIME:
		modulate.a = clampf(remaining / FADE_TIME, 0.0, 1.0)

	if resting:
		# Ease into the flat pose instead of freezing mid-tumble.
		rotation = lerp_angle(rotation, _rest_rotation, min(1.0, 10.0 * delta))
		return

	# Gravity, damping and the tumble -- same shape as Pickup._physics_process.
	linear_velocity += Vector2.DOWN * gravity * delta
	linear_velocity *= maxf(0.0, 1.0 - (linear_damp * delta))
	angular_velocity *= maxf(0.0, 1.0 - (angular_damp * delta))

	rotation += angular_velocity * delta

	var collision: KinematicCollision2D = move_and_collide(linear_velocity * delta)
	if collision != null:
		var normal := collision.get_normal()

		# Split the impact so the body keeps sliding along the ground instead of
		# being reflected straight back down the way Pickup does. `into` is the
		# component driving us into the surface (negative along the normal).
		var into := normal * linear_velocity.dot(normal)
		var along := linear_velocity - into
		linear_velocity = (along * SCRAPE) - (into * BOUNCE)

		# Scrubbing a spinning body against terrain kills the spin fast.
		angular_velocity *= -0.4

		# Push out of whatever we ended up inside of.
		move_and_collide(normal * collision.get_remainder().length())

		if linear_velocity.length() < REST_SPEED and absf(angular_velocity) < REST_SPIN:
			_settle()

func _settle() -> void:
	resting = true
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	# Nearest half turn: belly down or belly up, never standing on its nose.
	_rest_rotation = roundf(rotation / PI) * PI

# Keeps the arena from filling up. Called from _ready() after this corpse has
# joined the group, so `corpses` already includes us and the oldest bodies are
# the ones that go.
func _enforce_cap() -> void:
	var live := []
	for corpse in get_tree().get_nodes_in_group(GROUP):
		if is_instance_valid(corpse) and not corpse.is_queued_for_deletion():
			live.append(corpse)
	if live.size() <= MAX_CORPSES:
		return

	# Oldest first.
	live.sort_custom(func(a, b): return a.age > b.age)
	for i in range(live.size() - MAX_CORPSES):
		live[i].queue_free()
