extends Pickup

# Shared behaviour for the grenade and the mine: a fuse, a blast radius, and the
# rule that everyone standing in the radius dies -- the thrower included.
#
# --- Why the blast is arbitrated by one peer -------------------------------
#
# Every other kill in this game is decided by the VICTIM's peer (see
# components/Hitbox.gd), which works because a contact is a contact: both peers
# agree that two shapes touched. A blast radius is not like that. It is a
# snapshot of where everybody was at one instant, and remote players are
# simulated locally from a replayed input buffer, so each peer's snapshot is a
# few frames' worth of movement different from every other peer's. Let each peer
# measure its own radius and two of them will disagree about the player standing
# right on the edge -- alive on one screen, exploded on another.
#
# So: the peer that owns this pickup (the host, since pickups are spawned by
# objects/TimedGenerator.gd and never have their authority reassigned) measures
# the radius once and broadcasts the resulting list of victims. Every peer then
# plays the same explosion and kills the same names. The final
# is_multiplayer_authority() check on each victim is still there, because that
# is how a player's death is applied and replicated everywhere else.

var ExplodeEffect: PackedScene = preload("res://actors/ExplodeEffect.tscn")

# Fallbacks for a scene with no weapon_data; the .tres files override them.
@export var fuse_time: float = 2.0
@export var blast_radius: float = 130.0

# The 1-BASED physics layer players are on. Same layer every Hitbox masks.
const PLAYER_LAYER := 2

# Upper bound on bodies one blast can catch. Four players plus slack.
const MAX_BLAST_BODIES := 16

var fuse_lit := false
var fuse_left := 0.0

# Set on the peer that arbitrates, so a fuse that has already run out does not
# re-broadcast the blast on every subsequent frame.
var blast_requested := false

# Set on EVERY peer, by the blast RPC itself.
var exploded := false

func _apply_weapon_data() -> void:
	super._apply_weapon_data()

	if weapon_data == null:
		return

	if weapon_data.fuse_time > 0.0:
		fuse_time = weapon_data.fuse_time
	if weapon_data.blast_radius > 0.0:
		blast_radius = weapon_data.blast_radius

# Starts the countdown. Safe to call twice; the first call wins, so a cooked
# grenade does not get a fresh fuse when it is finally thrown.
func light_fuse() -> void:
	if fuse_lit or exploded:
		return
	fuse_lit = true
	fuse_left = fuse_time
	_on_fuse_lit()

func _on_fuse_lit() -> void:
	pass

# How far through the fuse we are, 0 -> 1. Used to drive the warning flash.
func get_fuse_progress() -> float:
	if not fuse_lit or fuse_time <= 0.0:
		return 0.0
	return clampf(1.0 - (fuse_left / fuse_time), 0.0, 1.0)

func _physics_process(delta: float) -> void:
	# Pickup's own physics bails out early while the weapon is held or asleep,
	# but a fuse has to keep burning in both of those cases -- cooking a grenade
	# in your hand is the whole point, and a mine lying still has to stay armed.
	super._physics_process(delta)

	if exploded:
		return

	if fuse_lit:
		fuse_left -= delta
		_update_fuse_visual()
		if fuse_left <= 0.0:
			trigger_blast()

func _update_fuse_visual() -> void:
	pass

# Asks for the blast. Only the arbitrating peer gets past the guard; the others
# just keep counting down and wait to be told.
func trigger_blast() -> void:
	if exploded or blast_requested:
		return
	if GameState.online_play and not is_multiplayer_authority():
		return

	blast_requested = true

	var victims := find_bodies_within(blast_radius)
	if GameState.online_play:
		rpc("_do_blast", global_position, victims)
	else:
		_do_blast(global_position, victims)

# Every player-shaped body within `radius`, as absolute node paths. Absolute so
# they resolve on every peer -- the same thing Player._try_pickup() relies on
# when it broadcasts the pickup it arbitrated.
func find_bodies_within(radius: float) -> Array:
	var found := []
	if radius <= 0.0:
		return found

	var world := get_world_2d()
	if world == null:
		return found

	var circle := CircleShape2D.new()
	circle.radius = radius

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = circle
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = 1 << (PLAYER_LAYER - 1)
	query.collide_with_bodies = true
	query.collide_with_areas = false

	for hit in world.direct_space_state.intersect_shape(query, MAX_BLAST_BODIES):
		var body = hit.get("collider")
		if body == null or not is_instance_valid(body):
			continue
		if not body.has_method("hurt"):
			continue
		found.append(body.get_path())
	return found

@rpc("any_peer", "call_local") func _do_blast(blast_position: Vector2, victims: Array) -> void:
	if exploded:
		return
	exploded = true

	_spawn_explosion(blast_position)

	# Hand ourselves back before anything else: if the holder is about to die
	# while carrying us, freeing this node would leave Player.current_pickup
	# pointing at a freed object.
	release_from_holder()

	for path in victims:
		var victim = get_node_or_null(path)
		if victim == null or not is_instance_valid(victim):
			continue
		if not victim.has_method("hurt"):
			continue
		# Same gate as components/Hitbox.gd: the list of who died is decided by
		# one peer, but applying a death is still the victim peer's job.
		if GameState.online_play and not victim.is_multiplayer_authority():
			continue
		victim.hurt(self)

	queue_free()

func _spawn_explosion(blast_position: Vector2) -> void:
	# actors/ExplodeEffect.tscn is somebody else's scene; it is only instanced
	# here, never edited. It emits once and frees itself on its own Timer.
	var parent: Node = original_parent
	if parent == null or not is_instance_valid(parent):
		parent = get_parent()
	if parent == null:
		return

	var effect = ExplodeEffect.instantiate()
	parent.add_child(effect)
	effect.global_position = blast_position

# Map.map_stop() reaches every pickup in the arena (Pickup.tscn is in the
# "map_object" group). A live explosive must not keep counting down on a round
# that is over -- see the note in Pickup.map_object_stop().
func map_object_stop() -> void:
	super.map_object_stop()
	fuse_lit = false
	blast_requested = true
	queue_free()
