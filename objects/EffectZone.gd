class_name EffectZone
extends Area2D

# A region of a map that does something to players inside it: launches them,
# kills them, or changes how they move. Drop one into a map, pick an effect,
# size its CollisionShape2D.
#
# Multiplayer note: every effect except KILL is a pure physics reaction, applied
# locally on each peer. Remote players are simulated from their replayed input
# buffer against the same map, so all peers reach the same result without any
# extra syncing. KILL is the exception -- it removes a player, so it is gated on
# authority exactly like components/Hitbox.gd.

enum Effect {
	## Bounce pad: launches a player upward on contact.
	LAUNCH,
	## Pit or void: kills a player who falls in.
	KILL,
	## Ice: much less friction, so players slide.
	SLIPPERY,
	## Tar or deep water: slower, and no jumping out.
	STICKY,
}

@export var effect: Effect = Effect.LAUNCH

## Set false to make a zone inert without removing it from the tree.
##
## Needed because a zone cannot be freed (or have its monitoring toggled) from
## inside a physics callback -- Godot refuses to change collision state while it
## is flushing queries. The sudden-death tide has to stop being lethal on the
## exact frame the round is decided, which is a frame it learns about from
## inside exactly such a callback, so it flips this instead.
@export var enabled: bool = true

@export_group("Launch")
## Upward speed applied on contact. The default clears roughly twice a normal
## jump (a normal jump is 700).
@export var launch_speed: float = 1150.0
## Seconds before the same player can be launched again, so sitting on a pad
## does not machine-gun them.
@export var relaunch_delay: float = 0.25

@export_group("Movement")
## Friction multiplier while inside (SLIPPERY).
@export var friction_scale: float = 0.12
## Speed multiplier while inside (STICKY).
@export var speed_scale: float = 0.55

signal player_launched (player)

var _last_launch := {}
var _kill_pending := {}

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _is_player(body: Node) -> bool:
	# Same duck-typing the rest of the project uses to tell players from
	# terrain, pickups and effects sharing a collision layer.
	return body.has_method("pickup_or_throw")

func _on_body_entered(body: Node) -> void:
	if not enabled or not _is_player(body):
		return

	match effect:
		Effect.LAUNCH:
			_try_launch(body)
		Effect.KILL:
			_try_kill(body)
		Effect.SLIPPERY, Effect.STICKY:
			if body.has_method("enter_effect_zone"):
				body.enter_effect_zone(self)

func _on_body_exited(body: Node) -> void:
	if not _is_player(body):
		return
	if body.has_method("exit_effect_zone"):
		body.exit_effect_zone(self)

func _process(_delta: float) -> void:
	# A player who lands on a pad and stays there should keep bouncing, but
	# body_entered only fires once -- so re-check while they overlap.
	#
	# KILL is swept for the same reason, plus one of its own: a kill zone that
	# MOVES or GROWS under a stationary player (the sudden-death tide does
	# exactly that) relies on the physics server noticing the new overlap. The
	# sweep makes "inside a kill zone" lethal by state rather than by event, so
	# no player can end up standing in one.
	if not enabled:
		return

	match effect:
		Effect.LAUNCH:
			for body in get_overlapping_bodies():
				if _is_player(body):
					_try_launch(body)
		Effect.KILL:
			for body in get_overlapping_bodies():
				if _is_player(body):
					_try_kill(body)

func _try_kill(body: Node) -> void:
	# Re-checked here and not only at the top of the callers: killing one player
	# can disable this zone (the sudden-death tide switches itself off the frame
	# the round is decided), and the caller may be part-way through a loop over
	# several overlapping bodies. Without this, the tide would take the winner
	# too on the very frame it was told to stop.
	if not enabled:
		return
	# Removing a player is not a local physics reaction, so only the peer that
	# owns them may decide it.
	if GameState.online_play and not body.is_multiplayer_authority():
		return
	# die() is not idempotent -- it spawns an explosion and RPCs -- and a body
	# already on its way out still shows up in get_overlapping_bodies().
	if body.is_queued_for_deletion():
		return

	# One pending kill per body: body_entered and the overlap sweep can both
	# reach the same player before the deferred call has run.
	var id := body.get_instance_id()
	if _kill_pending.has(id):
		return
	_kill_pending[id] = true

	# DEFERRED, because body_entered is emitted while the physics server is
	# flushing queries, and dying tears the player's own collision shapes down
	# (Player._explode_and_free). Doing that inline raises the engine's "cannot
	# change this state while flushing queries" -- which the pits have always been able to
	# provoke, and which the sudden-death tide provokes on every round it
	# decides. The cost is one frame of latency on a death, which nothing here
	# can observe.
	call_deferred("_deferred_kill", id)

func _deferred_kill(id: int) -> void:
	_kill_pending.erase(id)

	var body = instance_from_id(id)
	if body == null or not is_instance_valid(body):
		return
	# The world can have changed between the overlap and this call: the zone may
	# have been switched off (the tide does exactly that the moment the round is
	# decided), or the player may already be gone.
	if not enabled or body.is_queued_for_deletion():
		return
	if body.has_method("die"):
		body.die()

func _try_launch(body: Node) -> void:
	var id := body.get_instance_id()
	var now := float(Time.get_ticks_msec()) / 1000.0
	if _last_launch.has(id) and now - float(_last_launch[id]) < relaunch_delay:
		return
	_last_launch[id] = now

	body.vector.y = -launch_speed
	# Leaving the ground mid-state would otherwise keep the walk animation.
	if body.has_method("launch_from_zone"):
		body.launch_from_zone()
	emit_signal("player_launched", body)
