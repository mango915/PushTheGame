extends CharacterBody2D

var ExplodeEffect: PackedScene = preload("res://actors/ExplodeEffect.tscn")
var CorpseScene: PackedScene = preload("res://actors/Corpse.tscn")
var InputBuffer: RefCounted = preload("res://components/InputBuffer.gd")

enum PlayerSkin {
	ORANGE,
	GREEN,
	BLUE,
	PURPLE,
	MAX,
}

var skin_resources = [
	preload("res://assets/doodle/sprites/char_butter.png"),
	preload("res://assets/doodle/sprites/char_chili.png"),
	preload("res://assets/doodle/sprites/char_moody.png"),
	preload("res://assets/doodle/sprites/char_sprout.png"),
]

@export var player_skin : PlayerSkin = PlayerSkin.BLUE: set = set_player_skin

# All movement/throw tuning lives in this resource (res://resources/GameSettings.gd).
# Game.gd assigns the host's copy to every player on every peer, because remote
# players are simulated locally from their replayed input buffer -- differing
# numbers between peers desync the match with no error anywhere.
@export var settings: GameSettings

@export var invincible : bool = false
@export var player_controlled : bool = false
@export var input_prefix : String = "player1_"

# The settings actually in force. A Player instantiated without one (a test, or
# a scene dropped in by hand) falls back to the shipped defaults rather than
# reading null.
# --- Map effect zones (objects/EffectZone.gd) -------------------------------
#
# Ice, tar and the like. Kept as a set rather than a flag so overlapping zones
# compose correctly and leaving one does not cancel another.
var _effect_zones: Array = []
var speed_scale: float = 1.0
var friction_scale: float = 1.0
var jump_blocked: bool = false

func enter_effect_zone(zone: Node) -> void:
	if not _effect_zones.has(zone):
		_effect_zones.append(zone)
		_recompute_zone_effects()

func exit_effect_zone(zone: Node) -> void:
	if _effect_zones.has(zone):
		_effect_zones.erase(zone)
		_recompute_zone_effects()

func _recompute_zone_effects() -> void:
	speed_scale = 1.0
	friction_scale = 1.0
	jump_blocked = false

	# Prune anything freed since we last looked (a map can be torn down while
	# a player is still standing in one of its zones).
	var live := []
	for zone in _effect_zones:
		if not is_instance_valid(zone):
			continue
		live.append(zone)
		match zone.effect:
			EffectZone.Effect.SLIPPERY:
				friction_scale = min(friction_scale, zone.friction_scale)
			EffectZone.Effect.STICKY:
				speed_scale = min(speed_scale, zone.speed_scale)
				jump_blocked = true
	_effect_zones = live

# Called by a launch pad once it has set our upward velocity.
func launch_from_zone() -> void:
	if state_machine.current_state != null and state_machine.current_state.name != "Jump":
		state_machine.change_state("Jump", { "launched": true })
	sounds.play("Jump")

func get_settings() -> GameSettings:
	if settings == null:
		settings = GameSettings.new()
	return settings

# Read-only views onto the settings resource. These keep the property NAMES the
# player-state scripts already use (host.speed, host.friction, host.throw_*, ...)
# so actors/player-states/*.gd needs no changes.
var speed: float:
	get:
		return get_settings().speed * speed_scale

var acceleration: float:
	get:
		return get_settings().acceleration

var friction: float:
	get:
		return get_settings().friction * friction_scale

var sliding_friction: float:
	get:
		return get_settings().sliding_friction * friction_scale

var jump_speed: float:
	get:
		return get_settings().jump_speed

var glide_speed: float:
	get:
		return get_settings().glide_speed

var terminal_velocity: float:
	get:
		return get_settings().terminal_velocity

var push_back_speed: float:
	get:
		return get_settings().push_back_speed

var wall_jump_speed: float:
	get:
		return get_settings().wall_jump_speed

var wall_jump_push: float:
	get:
		return get_settings().wall_jump_push

var coyote_time: float:
	get:
		return get_settings().coyote_time

var jump_buffer_time: float:
	get:
		return get_settings().jump_buffer_time

# --- Coyote time and jump buffering ----------------------------------------
#
# Two halves of the same complaint. Without coyote time, stepping off a ledge
# eats the jump; without buffering, pressing jump a frame before landing eats
# it. Both feel like the game dropped an input the player definitely gave, and
# both are invisible in a screenshot.
#
# Counted in SECONDS off the physics delta rather than in frames, so they mean
# the same thing if the tick rate ever changes.
var _coyote_left := 0.0
var _jump_buffer_left := 0.0

# True while a jump is still allowed despite having left the ground.
func can_coyote_jump() -> bool:
	return _coyote_left > 0.0 and not jump_blocked

# Spends the grace, so one ledge cannot be used for two jumps.
func consume_coyote() -> void:
	_coyote_left = 0.0

# True if the player asked to jump just before touching down. Consumes it, so a
# single press cannot be replayed on later landings.
func consume_buffered_jump() -> bool:
	if _jump_buffer_left <= 0.0 or jump_blocked:
		return false
	_jump_buffer_left = 0.0
	return true

func _update_jump_assists(delta: float) -> void:
	if is_on_floor():
		_coyote_left = coyote_time
	else:
		_coyote_left = maxf(0.0, _coyote_left - delta)

	if input_buffer != null and input_buffer.is_action_just_pressed("jump"):
		_jump_buffer_left = jump_buffer_time
	else:
		_jump_buffer_left = maxf(0.0, _jump_buffer_left - delta)

# True when the player is airborne and pressed against a wall hard enough to
# kick off it.
#
# is_on_wall() reports what the LAST move_and_slide() found, and states run
# before this frame's move (see _physics_process), so this is always one frame
# old -- which is what we want: it is the contact the player can see.
func can_wall_jump() -> bool:
	if wall_jump_speed <= 0.0:
		return false
	if jump_blocked or is_on_floor():
		return false
	return is_on_wall()

var throw_velocity: float:
	get:
		return get_settings().throw_velocity

var throw_upward_velocity: float:
	get:
		return get_settings().throw_upward_velocity

var throw_vector_mix: float:
	get:
		return get_settings().throw_vector_mix

var throw_vector_max_length: float:
	get:
		return get_settings().throw_vector_max_length

var throw_torque: float:
	get:
		return get_settings().throw_torque

# 0 in the settings resource means "use the project's default gravity", which is
# what this used to read directly.
var gravity: float:
	get:
		return get_settings().get_gravity()

signal player_dead ()

@onready var initial_scale = scale
@onready var body_sprite: Sprite2D = $BodySprite
@onready var fin_sprite: Sprite2D = $FinSprite
@onready var back_pickup_position: Marker2D = $BackPickupPosition
@onready var front_pickup_position: Marker2D = $FrontPickupPosition
@onready var pickup_area: Area2D = $PickupArea
@onready var state_machine := $StateMachine
@onready var sprite_animation_player: AnimationPlayer = $SpriteAnimationPlayer
@onready var pickup_animation_player: AnimationPlayer = $PickupAnimationPlayer
@onready var sounds := $Sounds

@onready var standing_collision_shape := $StandingCollisionShape
@onready var ducking_collision_shape := $DuckingCollisionShape
@onready var sliding_collision_shape := $SlidingCollisionShape

var flip_h := false: set = set_flip_h
var show_gliding := false: set = set_show_gliding
var show_sliding := false: set = set_show_sliding

# The 1-BASED physics layer number, as shown in the project settings and as
# expected by set_collision_mask_value(). Layer 5 is "OneWayPlatforms" (see
# [layer_names] in project.godot) and is the layer Player.tscn's collision_mask
# of 17 (= layer 1 | layer 5) and PassThroughDetectorArea's mask of 16
# (= layer 5) both refer to.
#
# This used to be `ONE_WAY_PLATFORMS_COLLISION_BIT := 4`, a leftover from
# Godot 3's 0-INDEXED set_collision_mask_bit(). Godot 4's
# set_collision_mask_value() is 1-indexed, so 4 toggled layer 4 ("Pickup"),
# which is not even in the player's mask -- drop-through silently did nothing.
# Named ..._LAYER (not ..._BIT) so the two numbering schemes cannot be confused
# again.
const ONE_WAY_PLATFORMS_COLLISION_LAYER := 5

# The one peer that arbitrates contested pickups. See _try_pickup()/_do_pickup().
const HOST_PEER_ID := 1

var pass_through_one_way_platforms := false: set = set_pass_through_one_way_platforms

var vector := Vector2.ZERO
var current_pickup: CharacterBody2D
var current_pickup_position: Marker2D

const PlayerActions := ['left', 'right', 'down', 'jump', 'grab', 'use', 'blop']
var input_buffer

var sync_forced := false
var sync_counter: int = 0
var sync_state_info := {}

# True when the remote input buffer holds JUST_PRESSED/JUST_RELEASED flags that
# no physics frame has looked at yet. See _apply_remote_input().
var remote_input_pending := false

func _ready():
	# Disable the state machine node's _physics_process() so that we can run
	# it manually from here, and ensure everything happens in the right order.
	state_machine.set_physics_process(false)

	body_sprite.texture = skin_resources[player_skin]
	# The whales had a separate fin sprite; the Scribble characters are one
	# piece, so it is hidden rather than removed -- Player.tscn is shared and
	# other code still resolves the node.
	if fin_sprite != null:
		fin_sprite.visible = false
	_set_squash(1.0, 1.0, true)
	reset_state()

func set_player_skin(_player_skin: int) -> void:
	if player_skin != _player_skin and _player_skin < PlayerSkin.MAX and _player_skin >= 0:
		player_skin = _player_skin

		if body_sprite != null:
			body_sprite.texture = skin_resources[player_skin]
			fin_sprite.texture = skin_resources[player_skin]

# Shows the player's name above their character. Built in code so Player.tscn
# does not have to change.
#
# The label is top_level, so it ignores the player's transform entirely and is
# positioned in global coordinates each frame. Parenting it normally and
# counter-scaling does NOT work: flipping negates the player's scale.x, and the
# pickup AnimationPlayer re-animates that scale, so the label would be left
# mirrored whenever an animation reset the flip.
# Where the label's BOTTOM edge sits, in the player's own coordinates.
#
# The player's origin is at their FEET: StandingCollisionShape is 56 tall at
# y = -28 (so the body spans y = -56..0), and BodySprite is 76x66 centred at
# y = -31 (so the whale occupies y = -64..+2). This was -46, which is two thirds
# of the way UP the sprite -- the name rendered across the character's own body,
# where it was close to unreadable against the art. Clearing the sprite top puts
# it on the flat background instead.
const NAME_LABEL_BOTTOM := -70.0

# Used for the frame before the Label has been laid out and reports a real size.
const NAME_LABEL_FALLBACK_CHAR_WIDTH := 7.0
const NAME_LABEL_FALLBACK_HEIGHT := 18.0

var player_name: String = ""
var _name_label: Label

func set_player_name(_player_name: String) -> void:
	player_name = _player_name

	if _name_label == null:
		_name_label = Label.new()
		_name_label.name = "NameLabel"
		_name_label.top_level = true
		_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_name_label.add_theme_font_size_override("font_size", 12)
		_name_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
		# A dark outline keeps the name readable against both the pale water and
		# the dark terrain.
		_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		_name_label.add_theme_constant_override("outline_size", 4)
		_name_label.z_index = 10
		add_child(_name_label)

	_name_label.text = player_name
	_update_name_label()

func _update_name_label() -> void:
	if _name_label == null:
		return

	var width := _name_label.size.x
	if width <= 0.0:
		width = float(len(player_name)) * NAME_LABEL_FALLBACK_CHAR_WIDTH
	var height := _name_label.size.y
	if height <= 0.0:
		height = NAME_LABEL_FALLBACK_HEIGHT

	# A Label is positioned by its top-left corner, so the height has to come
	# off for NAME_LABEL_BOTTOM to mean the bottom of the text.
	_name_label.global_position = global_position \
		+ Vector2(0, NAME_LABEL_BOTTOM) \
		- Vector2(width * 0.5, height)

func _process(_delta: float) -> void:
	# top_level means the label does not follow us automatically.
	if _name_label != null:
		_update_name_label()

	_update_squash(_delta)
	_update_flash(_delta)

	# Lean into a run, and level out when not moving. Reads as weight without
	# needing a walk cycle the art does not have.
	if body_sprite != null:
		var lean := 0.0
		if is_on_floor() and absf(vector.x) > 20.0:
			lean = clampf(vector.x / max(1.0, speed), -1.0, 1.0) * 0.16
			if flip_h:
				lean = -lean
		body_sprite.rotation = lerpf(body_sprite.rotation, lean, clampf(10.0 * _delta, 0.0, 1.0))

func set_flip_h(_flip_h: bool) -> void:
	if flip_h != _flip_h:
		flip_h = _flip_h

		if flip_h:
			scale.x = -initial_scale.x * sign(scale.y)
		else:
			scale.x = initial_scale.x * sign(scale.y)

func set_pass_through_one_way_platforms(_pass_through: bool) -> void:
	if pass_through_one_way_platforms != _pass_through:
		pass_through_one_way_platforms = _pass_through
		set_collision_mask_value(ONE_WAY_PLATFORMS_COLLISION_LAYER, !_pass_through)

# Down + jump on a one-way platform. Clears the platform layer from our mask and
# gives a nudge downward, because from a standing start there is no downward
# velocity at all and the player would simply sit there.
#
# The flag is cleared by PassThroughDetectorArea once we are genuinely below the
# platform; DROP_THROUGH_TIMEOUT is the backstop for a drop that never resolves
# (walking off the side mid-drop, say), so a player cannot end up permanently
# unable to stand on one-way platforms.
const DROP_THROUGH_NUDGE := 60.0
const DROP_THROUGH_TIMEOUT := 0.4

var _drop_through_left := 0.0

func drop_through() -> void:
	if jump_blocked:
		return
	pass_through_one_way_platforms = true
	_drop_through_left = DROP_THROUGH_TIMEOUT
	if vector.y < DROP_THROUGH_NUDGE:
		vector.y = DROP_THROUGH_NUDGE

func _update_drop_through(delta: float) -> void:
	if _drop_through_left <= 0.0:
		return
	_drop_through_left -= delta
	if _drop_through_left <= 0.0:
		pass_through_one_way_platforms = false

func _on_PassThroughDetectorArea_body_exited(body: Node) -> void:
	_drop_through_left = 0.0
	self.pass_through_one_way_platforms = false

func set_show_gliding(_show_gliding: bool) -> void:
	if show_gliding != _show_gliding:
		show_gliding = _show_gliding

		if show_gliding:
			pickup_animation_player.play("RotateUp")
		else:
			pickup_animation_player.play_backwards("RotateUp")

func set_show_sliding(_show_sliding: bool) -> void:
	if show_sliding != _show_sliding:
		show_sliding = _show_sliding

		if show_sliding:
			pickup_animation_player.play("Slide")
		else:
			pickup_animation_player.play("Idle")

# ---------------------------------------------------------------------------
# Squash and stretch
#
# The Scribble characters are a single static sprite each -- no animation frames
# at all, where the whales had 154. So motion comes from the TRANSFORM instead:
# a body stretches as it leaves the ground, squashes as it lands, leans into a
# run, and flinches when hit.
#
# Purely cosmetic. Nothing here is read by physics, by the state machine or by
# the sync -- a remote player is replayed from their input buffer and arrives at
# these poses on its own, so none of it has to travel over the wire.
#
# Applied to BodySprite rather than to the player: the player's own scale.x
# carries flip_h, and the pickup AnimationPlayer animates that same scale, so
# squashing there would fight both.
# ---------------------------------------------------------------------------

# Where the sprite sits when unsquashed. Scaling happens about the FEET, not the
# sprite centre, so a squashed body stays planted instead of sinking.
const BODY_REST_Y := -34.0
# How fast the current pose chases the target. High enough to feel snappy,
# low enough that a landing still reads as a bounce.
const SQUASH_RESPONSE := 14.0

var _squash := Vector2.ONE
var _squash_target := Vector2.ONE

# Downward speed at the moment of the last landing, so a drop from a great
# height lands harder than a hop off a kerb. Every landing used to squash by
# exactly the same amount, which reads as weightless.
var _impact_speed := 0.0

# The squash of hitting the ground, scaled by how fast we were falling: a hop
# barely registers, a drop from the top of the arena flattens you.
#
# Separate from the "Land" ANIMATION on purpose. Landing while holding a
# direction goes Fall -> Move, which plays "Walk" and never touches "Land", so
# running landings -- almost all of them in a platformer -- used to arrive with
# no impact at all. The impulse belongs to the landing, not to one state.
func land_impact() -> void:
	var hit := clampf(_impact_speed / maxf(1.0, terminal_velocity), 0.0, 1.0)
	_impulse_squash(lerpf(1.05, 1.34, hit), lerpf(0.95, 0.66, hit))

# A jump the tar refused. Kicks the body once so the press is visibly received.
func stuck_bump() -> void:
	_impulse_squash(1.22, 0.82)
	if sounds != null and sounds.has_node("Jump"):
		sounds.play("Jump")

func _set_squash(x: float, y: float, immediate: bool = false) -> void:
	_squash_target = Vector2(x, y)
	if immediate:
		_squash = _squash_target

# A one-off hit: snap the body to a pose and let it spring straight back.
#
# Distinct from _set_squash(immediate) which also moves the TARGET, so the body
# eases INTO the pose and stays there. That is right for a held pose like Duck,
# and wrong for an impact -- a landing set the squashed pose as the target, so
# the body kept compressing for as long as the Land animation ran and read as a
# crouch rather than as hitting the ground.
func _impulse_squash(x: float, y: float) -> void:
	_squash = Vector2(x, y)
	_squash_target = Vector2.ONE

# A brief tint, so a hit reads on the frame it happens rather than only through
# the state change. Purely cosmetic, like the squash.
const FLASH_SECONDS := 0.12
var _flash_left := 0.0
var _flash_color := Color.WHITE

func _flash(color: Color) -> void:
	_flash_color = color
	_flash_left = FLASH_SECONDS

func _update_flash(delta: float) -> void:
	if body_sprite == null:
		return
	if _flash_left <= 0.0:
		if body_sprite.modulate != Color.WHITE:
			body_sprite.modulate = Color.WHITE
		return
	_flash_left -= delta
	body_sprite.modulate = _flash_color if _flash_left > 0.0 else Color.WHITE

# How far the body is pressed down while stuck in tar. Enough to read as
# "something has hold of you", not so much that it looks like a duck.
const STUCK_SQUASH := Vector2(1.12, 0.86)

func _update_squash(delta: float) -> void:
	if body_sprite == null:
		return

	var target := _squash_target
	# Composed with whatever pose the state asked for, rather than replacing it,
	# so a player wading through tar still reads as walking.
	if jump_blocked and is_on_floor():
		target = Vector2(target.x * STUCK_SQUASH.x, target.y * STUCK_SQUASH.y)

	_squash = _squash.lerp(target, clampf(SQUASH_RESPONSE * delta, 0.0, 1.0))
	body_sprite.scale = _squash
	body_sprite.position.y = BODY_REST_Y * _squash.y

func play_animation(name) -> void:
	sprite_animation_player.play(name)

	# The pose each state reads as. Landing and being hit are one-shot impulses
	# -- set immediately and allowed to recover -- while the rest are targets
	# the body eases towards.
	match name:
		"Jump", "Glide":
			_set_squash(0.86, 1.18)
		"Fall":
			_set_squash(0.92, 1.10)
		"Land":
			land_impact()
		"Duck":
			_set_squash(1.18, 0.72)
		"Slide", "SlideFinished":
			_set_squash(1.30, 0.70)
		"Hurt":
			_impulse_squash(1.24, 0.80)
			_flash(Color(1.6, 0.5, 0.5))
		"Blop":
			_impulse_squash(0.84, 1.16)
		_:
			_set_squash(1.0, 1.0)

func get_current_animation() -> String:
	return sprite_animation_player.current_animation

func _on_BodySprite_frame_changed() -> void:
	if not fin_sprite or not body_sprite:
		await self.ready
	fin_sprite.frame = body_sprite.frame + 7

func reset_state() -> void:
	var current_state_name = state_machine.current_state.name if state_machine.current_state != null else "None"
	if current_state_name != "Idle":
		state_machine.change_state("Idle")
	set_flip_h(false)
	visible = true

# ---------------------------------------------------------------------------
# RPC sender validation.
#
# Every player node lives at a fixed path (Players/<peer_id>) and every state
# RPC below is declared "any_peer", so without these checks ANY peer could
# teleport, freeze, disarm or kill ANY other player just by rpc-ing that node.
#
# get_remote_sender_id() is 0 when the method was invoked as a plain local
# function call (single-player, or an internal call), and is our own unique id
# for the local half of an rpc(..., "call_local"). Both are legitimate.
# ---------------------------------------------------------------------------

func _sender_is(expected_peer_id: int) -> bool:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		# Not an RPC at all -- a direct local call.
		return true
	return sender == expected_peer_id

# True when the packet came from the peer that owns this player (or was a local
# call). This is the right check for anything the owner drives.
func _sender_is_authority() -> bool:
	return _sender_is(get_multiplayer_authority())

func pickup_or_throw() -> void:
	if not GameState.online_play:
		if current_pickup:
			_do_throw()
		else:
			_try_pickup()
	else:
		if current_pickup:
			# We throw on all clients; the pickup knows to simulate physics
			# only on the master, and sync to the puppets.
			rpc("_do_throw")
		else:
			# We try to pickup only on the host so it can make sure that
			# only one client gets it, and then the host will tell everyone
			# else.
			rpc_id(1, "_try_pickup")

# Asked for by the owning peer and answered by the host, so that two players
# grabbing the same weapon on the same frame cannot both get it. The only peer
# allowed to ask is the one that owns this player.
@rpc("any_peer", "call_local") func _try_pickup() -> void:
	if not _sender_is_authority():
		return

	for body in pickup_area.get_overlapping_bodies():
		# PickupArea's mask is the "Pickup" layer, but Map1's inline TileSet puts
		# its terrain on *every* physics layer, so the TileMap comes back here
		# too. Without this guard, grabbing next to a wall raised "Nonexistent
		# function 'can_pickup' in base 'TileMap'" and aborted the whole loop,
		# so a weapon lying against a wall could never be picked up.
		# Same shape of guard as components/Hitbox.gd's has_method('hurt').
		if not body.has_method("can_pickup"):
			continue
		if not body.can_pickup():
			continue
		body.pickup_state = Pickup.PickupState.PICKED_UP

		if GameState.online_play:
			rpc("_do_pickup", body.get_path())
		else:
			_do_pickup(body.get_path())

		return

# Broadcast by the host after _try_pickup() has arbitrated, so the sender we
# expect here is the host -- NOT this node's authority, which is usually a
# different peer.
@rpc("any_peer", "call_local") func _do_pickup(pickup_path: NodePath) -> void:
	if not _sender_is(HOST_PEER_ID):
		return

	sounds.play("Pickup")
	current_pickup = get_node(pickup_path)
	current_pickup.pickup(self)
	current_pickup.get_parent().remove_child(current_pickup)

	current_pickup_position = back_pickup_position if current_pickup.pickup_position == Pickup.PickupPosition.BACK else front_pickup_position
	current_pickup_position.add_child(current_pickup)
	current_pickup.position = -current_pickup.held_position.position

@rpc("any_peer", "call_local") func _do_throw() -> void:
	if not _sender_is_authority():
		return

	if current_pickup == null:
		return

	sounds.play("Throw")
	var throw_vector = (vector * throw_vector_mix) + ((Vector2.LEFT if flip_h else Vector2.RIGHT) * throw_velocity)
	throw_vector += Vector2.UP * throw_upward_velocity

	# Disconnect from our pickup position.

	current_pickup_position.remove_child(current_pickup)
	current_pickup.original_parent.add_child(current_pickup)
	current_pickup.global_position = current_pickup_position.global_position

	current_pickup.throw(current_pickup_position.global_position, throw_vector.limit_length(throw_vector_max_length), throw_torque)
	current_pickup = null
	current_pickup_position = null

func try_use() -> void:
	if not current_pickup:
		return
	current_pickup.use()

# Only weapons that charge care; everything else inherits a no-op.
func try_use_release() -> void:
	if not current_pickup:
		return
	if current_pickup.has_method("use_release"):
		current_pickup.use_release()

func hurt(node: Node2D) -> void:
	# Declared as an @export since forever but never actually read, so the
	# inspector checkbox did nothing. An invincible player takes no damage.
	if invincible:
		return

	if current_pickup and current_pickup == node.get_parent():
		# Prevent cutting yourself with your own sword.
		return

	var current_state_name = state_machine.current_state.name if state_machine.current_state != null else "None"
	if current_state_name == "Hurt" or current_state_name == "Dead":
		return

	var push_back_vector = (global_position - node.global_position).normalized() * push_back_speed

	state_machine.change_state("Hurt", {
		push_back_vector = push_back_vector,
	})

# --- Death cosmetics ---------------------------------------------------------
#
# The corpse and the gibs are decoration. They are spawned from
# _explode_and_free(), which every peer already reaches (see _do_die() and
# force_remove()), and they are never networked themselves -- see the header of
# actors/Corpse.gd.

# The last push this player took, remembered only so the corpse can be flung the
# same way. Recorded by actors/player-states/Hurt.gd rather than by hurt():
# Hitbox only calls hurt() on the victim's own peer, but the Hurt state and its
# info dictionary are replicated to every peer through update_remote_player(), so
# recording it in the state is the one place that runs everywhere.
var last_hit_vector := Vector2.ZERO

# push_back_speed is tuned for how far a hit shoves a LIVING player (50 px/s by
# default), which is nowhere near enough to throw a body. These turn it into a
# launch without touching the gameplay number.
const CORPSE_IMPULSE_SCALE := 7.0
const CORPSE_LAUNCH_UP := 260.0

# How much of the dying player's own momentum the body keeps.
const CORPSE_MOMENTUM := 0.5

# The player's origin is at its feet; the sprite is drawn a frame's worth above
# it (BodySprite sits at (0, -31) once its position and offset are combined).
# The corpse's origin is the middle of its sprite so that it tumbles about its
# body rather than about a point under its chin.
const CORPSE_SPAWN_OFFSET := Vector2(0, -31)

func note_hit(push_back_vector: Vector2) -> void:
	last_hit_vector = push_back_vector

func die() -> void:
	if GameState.online_play:
		if is_multiplayer_authority():
			if current_pickup:
				rpc("_do_throw")
			rpc("_do_die")
	else:
		if current_pickup:
			_do_throw()
		_do_die();

# Removes this player unconditionally, regardless of who has authority.
# Used when the owning peer has disconnected, so no peer is its authority
# and the normal die() path silently does nothing on every machine.
# Every peer calls this locally -- it never RPCs, and it deliberately does not
# go through the _do_die() RPC entry point so that a caller inside some other
# peer's RPC handler cannot be mistaken for a spoofed packet.
func force_remove() -> void:
	if is_queued_for_deletion():
		return
	_explode_and_free()

@rpc("any_peer", "call_local") func _do_die() -> void:
	if not _sender_is_authority():
		return
	_explode_and_free()

func _explode_and_free() -> void:
	var parent := get_parent()

	# Exactly ONE explosion per death. This used to be spawned here AND in
	# Dead._state_enter(); tests/smoke_test.gd and tests/ragdoll_test.gd both
	# count the CPUParticles2D children of the Players container to keep it that
	# way, which is also why the gibs are a child of the corpse and not of the
	# container.
	var explosion = ExplodeEffect.instantiate()
	parent.add_child(explosion)
	explosion.global_position = global_position

	_spawn_corpse(parent)

	queue_free()
	emit_signal("player_dead")

# Drops a cosmetic ragdoll where the player just died.
#
# Parented next to the explosion, in the Players container, for two reasons: it
# is what the death effect already does, and that container is emptied by
# Game.game_stop() at the end of every round, so bodies never outlive their
# match. It is safe there because nothing treats the container's children as
# players without asking first -- Camera.gd and Game/smoke-test code filter on
# has_method("pickup_or_throw"), and a corpse deliberately has no such method.
func _spawn_corpse(parent: Node) -> void:
	if parent == null or CorpseScene == null:
		return

	var corpse = CorpseScene.instantiate()
	parent.add_child(corpse)
	corpse.global_position = global_position + CORPSE_SPAWN_OFFSET

	var impulse := last_hit_vector * CORPSE_IMPULSE_SCALE
	if impulse.length() > 0.0:
		# Hit deaths pop upward as well as away; a quiet death (drowning in the
		# round timer, a disconnect, a fall) just drops the body.
		impulse += Vector2.UP * CORPSE_LAUNCH_UP

	corpse.setup(player_skin, vector * CORPSE_MOMENTUM, impulse, flip_h)

func _play_blop_sound() -> void:
	sounds.play("Blop")

func _physics_process(delta: float) -> void:
	# Initialize the input buffer.
	if input_buffer == null:
		input_buffer = InputBuffer.new(PlayerActions, input_prefix)

	var input_buffer_changed := false
	if player_controlled:
		input_buffer_changed = input_buffer.update_local()

	_update_jump_assists(delta)
	_update_drop_through(delta)
	state_machine._physics_process(delta)

	vector.y += (gravity * delta)
	if vector.y > terminal_velocity:
		vector.y = terminal_velocity
	var falling_at := vector.y
	var was_airborne := not is_on_floor()

	set_velocity(vector)
	set_up_direction(Vector2.UP)
	move_and_slide()
	vector = velocity

	# Landing impact, for the squash. Read from before the move because
	# move_and_slide() zeroes the downward component on contact.
	if was_airborne and is_on_floor() and falling_at > 0.0:
		_impact_speed = falling_at

	if GameState.online_play:
		if player_controlled:
			# Sync every so many physics frames.
			sync_counter += 1
			if sync_forced or input_buffer_changed or sync_counter >= get_settings().sync_delay:
				sync_counter = 0
				sync_forced = false
				rpc("update_remote_player", input_buffer.buffer, state_machine.current_state.name, sync_state_info, global_position, vector, flip_h, show_gliding, show_sliding, pass_through_one_way_platforms)
				if sync_state_info.size() > 0:
					sync_state_info.clear()
		else:
			# The state machine above has now seen this frame's buffer, so any
			# edge-triggered flags in it are spent and must not leak into the
			# next frame.
			input_buffer.predict_next_frame()
			remote_input_pending = false

# `frame` (the sender's body_sprite.frame) used to be a parameter here and was
# never read: remote players are simulated from their replayed input buffer and
# their sprite frame is driven by their own AnimationPlayer. It has been REMOVED
# from both ends rather than applied, because applying it would fight the local
# animation, and it cost bandwidth in every single sync packet.
@rpc("any_peer") func update_remote_player(_input_buffer: Dictionary, current_state: String, state_info: Dictionary, _position: Vector2, _vector: Vector2, _flip_h: bool, _show_gliding: bool, _show_sliding: bool, _pass_through: bool) -> void:
	# Only the peer that owns this player may drive it. Player nodes are named
	# after their peer id at a well-known path, so without this check any peer
	# could move, freeze or teleport anyone else's character.
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return

	# Initialize the input buffer.
	if input_buffer == null:
		input_buffer = InputBuffer.new(PlayerActions, input_prefix)

	_apply_remote_input(_input_buffer)
	state_machine.change_state(current_state, state_info)
	global_position = _position
	vector = _vector
	set_flip_h(_flip_h)
	set_show_gliding(_show_gliding)
	set_show_sliding(_show_sliding)
	set_pass_through_one_way_platforms(_pass_through)

# Installs a freshly received input buffer for a remote player.
#
# A whole-buffer replace loses inputs. JUST_PRESSED/JUST_RELEASED are
# edge-triggered and live for exactly one physics frame; the sender emits a
# packet on every frame its buffer changes, so a single tap produces two packets
# one frame apart (edge set, then edge cleared). Whenever render fps exceeds
# physics fps -- the normal case -- both can be delivered in the same
# MultiplayerAPI poll, and the second packet wiped the edge before any physics
# frame observed it. The remote player visibly skipped the jump.
#
# So: OR unconsumed edges forward instead of overwriting them. They are still
# cleared by predict_next_frame() at the end of the very next physics frame, so
# an input cannot stick for longer than the single frame it was meant to last.
func _apply_remote_input(incoming: Dictionary) -> void:
	var previous: Dictionary = input_buffer.buffer

	if remote_input_pending:
		for action in previous:
			if not incoming.has(action):
				continue
			var was: Dictionary = previous[action]
			var now: Dictionary = incoming[action]
			if was.get(InputBuffer.ActionType.JUST_PRESSED, false):
				now[InputBuffer.ActionType.JUST_PRESSED] = true
			if was.get(InputBuffer.ActionType.JUST_RELEASED, false):
				now[InputBuffer.ActionType.JUST_RELEASED] = true

	input_buffer.buffer = incoming

	remote_input_pending = false
	for action in incoming:
		var entry: Dictionary = incoming[action]
		if entry.get(InputBuffer.ActionType.JUST_PRESSED, false) \
				or entry.get(InputBuffer.ActionType.JUST_RELEASED, false):
			remote_input_pending = true
			break

func _on_StateMachine_state_changed(state, info: Dictionary) -> void:
	sync_forced = true
	sync_state_info = info

