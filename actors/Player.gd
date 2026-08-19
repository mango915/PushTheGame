extends CharacterBody2D

var ExplodeEffect: PackedScene = preload("res://actors/ExplodeEffect.tscn")
var InputBuffer: RefCounted = preload("res://components/InputBuffer.gd")

enum PlayerSkin {
	ORANGE,
	GREEN,
	BLUE,
	PURPLE,
	MAX,
}

var skin_resources = [
	preload("res://assets/sprites/whale_orange.png"),
	preload("res://assets/sprites/whale_green.png"),
	preload("res://assets/sprites/whale_blue.png"),
	preload("res://assets/sprites/whale_purple.png"),
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
	fin_sprite.texture = skin_resources[player_skin]
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
const NAME_LABEL_OFFSET := Vector2(0, -46)

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
		_name_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
		# A dark outline keeps the name readable against both the pale water and
		# the dark terrain.
		_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
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
		width = float(len(player_name)) * 7.0
	_name_label.global_position = global_position + NAME_LABEL_OFFSET - Vector2(width * 0.5, 0)

func _process(_delta: float) -> void:
	# top_level means the label does not follow us automatically.
	if _name_label != null:
		_update_name_label()

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

func _on_PassThroughDetectorArea_body_exited(body: Node) -> void:
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

func play_animation(name) -> void:
	sprite_animation_player.play(name)

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
	var explosion = ExplodeEffect.instantiate()
	get_parent().add_child(explosion)
	explosion.global_position = global_position

	queue_free()
	emit_signal("player_dead")

func _play_blop_sound() -> void:
	sounds.play("Blop")

func _physics_process(delta: float) -> void:
	# Initialize the input buffer.
	if input_buffer == null:
		input_buffer = InputBuffer.new(PlayerActions, input_prefix)

	var input_buffer_changed := false
	if player_controlled:
		input_buffer_changed = input_buffer.update_local()

	state_machine._physics_process(delta)

	vector.y += (gravity * delta)
	if vector.y > terminal_velocity:
		vector.y = terminal_velocity
	set_velocity(vector)
	set_up_direction(Vector2.UP)
	move_and_slide()
	vector = velocity

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

