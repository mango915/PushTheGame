extends "res://pickups/Explosive.gd"

# Cook and throw.
#
# Press use to light the fuse in your hand -- which is a real decision, because
# the blast does not care that you are the one holding it -- or just throw it
# and let the fuse start on release. Either way it bounces off geometry on the
# way (Pickup's own physics, with a high `bounce` in grenade_weapon.tres) and
# then takes out everyone inside blast_radius.

@onready var sprite: Sprite2D = get_node_or_null("Sprite2D")

# Cooking is driven by the holding player's input, which in an online match only
# runs on that player's own peer (see actors/player-states/Idle.gd). So the
# decision has to be broadcast, exactly as Sword.use() broadcasts its swing --
# otherwise the other peers' grenades would sit unlit and never explode.
func use() -> void:
	if fuse_lit or exploded:
		return

	if not GameState.online_play:
		_do_light_fuse()
	else:
		rpc("_do_light_fuse")

@rpc("any_peer", "call_local") func _do_light_fuse() -> void:
	light_fuse()

func _on_throw() -> void:
	# Player._do_throw() is an @rpc(..., "call_local") method, so throw() -- and
	# therefore this -- already runs on every peer. No broadcast needed, and
	# light_fuse() ignores the call if the grenade was cooked first.
	light_fuse()

func _on_fuse_lit() -> void:
	if sprite != null:
		sprite.modulate = Color(1.0, 0.55, 0.35)

# Flash faster and faster as the fuse burns down, so "get away from that" is
# readable without a HUD.
func _update_fuse_visual() -> void:
	if sprite == null:
		return
	var progress := get_fuse_progress()
	# ~3Hz at the start, ~12Hz just before the blast.
	var rate := 3.0 + (progress * 9.0)
	var on := fmod(progress * fuse_time * rate, 1.0) < 0.5
	sprite.modulate = Color(1.0, 0.35, 0.25) if on else Color(1.0, 0.95, 0.7)
