extends "res://pickups/Gun.gd"

# Short range, a fan of pellets, and a shove hard enough to be a tactic in its
# own right -- this is Push The Game, and putting someone in a pit counts.
#
# Everything about actually firing is Gun.gd's: the cooldown, the ammo, the
# Shoot animation's method track, the dud detector, and the RPC that tells every
# peer which projectiles to spawn. The shotgun is that same flow with
# pellet_count/spread_degrees/knockback/recoil turned up in
# res://resources/shotgun_weapon.tres, plus the pattern below.

# A denser core than Gun's evenly-spaced fan.
#
# An even pellet count spread evenly leaves a GAP on the barrel line, so a
# target dead ahead at range can sit in the hole between the two middle pellets
# and take nothing. Easing the pellets towards the centre (cube of the -1..1
# position across the fan) keeps the outermost pair at the full spread while
# bunching the rest near the middle, so aiming straight at someone is always the
# right answer and the spread only decides how much you also catch either side.
func get_pellet_angles() -> PackedFloat32Array:
	var pellets := maxi(1, pellet_count)
	if pellets == 1 or spread_degrees <= 0.0:
		return super.get_pellet_angles()

	var half := deg_to_rad(spread_degrees) * 0.5
	var angles := PackedFloat32Array()
	for i in range(pellets):
		# -1 .. +1 across the fan.
		var t := (float(i) / float(pellets - 1)) * 2.0 - 1.0
		angles.append(half * t * t * t)
	return angles
