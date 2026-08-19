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

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _is_player(body: Node) -> bool:
	# Same duck-typing the rest of the project uses to tell players from
	# terrain, pickups and effects sharing a collision layer.
	return body.has_method("pickup_or_throw")

func _on_body_entered(body: Node) -> void:
	if not _is_player(body):
		return

	match effect:
		Effect.LAUNCH:
			_try_launch(body)
		Effect.KILL:
			# Removing a player is not a local physics reaction, so only the
			# peer that owns them may decide it.
			if not GameState.online_play or body.is_multiplayer_authority():
				if body.has_method("die"):
					body.die()
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
	if effect != Effect.LAUNCH:
		return
	for body in get_overlapping_bodies():
		if _is_player(body):
			_try_launch(body)

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
