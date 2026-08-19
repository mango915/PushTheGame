extends "res://pickups/Explosive.gd"

# Drop it, walk away, wait for someone else to walk into it.
#
# The arming delay is the point of the weapon: for arm_delay seconds after it
# leaves your hand a mine is inert, so you cannot drop one on somebody's head
# (or your own feet) and get a kill out of it. After that it detonates as soon
# as any player comes within trigger_radius.

@onready var sprite: Sprite2D = get_node_or_null("Sprite2D")

@export var arm_delay: float = 1.5
@export var trigger_radius: float = 55.0

var dropped := false
var armed := false
var arm_left := 0.0

func _apply_weapon_data() -> void:
	super._apply_weapon_data()

	if weapon_data == null:
		return

	if weapon_data.arm_delay > 0.0:
		arm_delay = weapon_data.arm_delay
	if weapon_data.trigger_radius > 0.0:
		trigger_radius = weapon_data.trigger_radius

func _on_throw() -> void:
	# Runs on every peer (Player._do_throw is call_local), so every peer arms
	# its copy on the same frame and the visual state agrees everywhere. Only
	# the arbitrating peer ever acts on it -- see trigger_blast().
	dropped = true
	armed = false
	arm_left = arm_delay
	_update_arm_visual()

func pickup(_player: Node2D) -> void:
	# Picking a mine back up disarms it, so one can be recovered and re-placed.
	super.pickup(_player)
	dropped = false
	armed = false
	arm_left = 0.0
	_update_arm_visual()

func _physics_process(delta: float) -> void:
	super._physics_process(delta)

	if exploded or not dropped:
		return

	if not armed:
		arm_left -= delta
		if arm_left <= 0.0:
			armed = true
			_update_arm_visual()
		return

	if blast_requested:
		return
	# Only the peer that arbitrates the blast bothers to look; the rest are told.
	if GameState.online_play and not is_multiplayer_authority():
		return
	if not find_bodies_within(trigger_radius).is_empty():
		trigger_blast()

func _update_arm_visual() -> void:
	if sprite == null:
		return
	if armed:
		sprite.modulate = Color(1.0, 0.25, 0.25)
	elif dropped:
		sprite.modulate = Color(0.6, 0.6, 0.65)
	else:
		sprite.modulate = Color(1.0, 1.0, 1.0)
