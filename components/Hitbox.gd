extends Area2D

@export var disabled : bool = false: set = set_disabled

# --- Knockback --------------------------------------------------------------
#
# Push The Game is named after shoving people off things, so a weapon needs to
# be able to do more than kill: a shotgun blast should launch its victim. Both
# default to 0, so every hitbox that shipped before this (the sword, the gun's
# projectile) behaves exactly as it did.
#
# Player.hurt() already applies GameSettings.push_back_speed (50px/s, barely a
# nudge) and cannot be extended from here -- actors/Player.gd is not ours -- so
# the extra shove is added on top, after hurt() has set the victim's vector.

## Horizontal shove, in px/s, away from this hitbox.
@export var knockback : float = 0.0

## Upward shove, in px/s. Lofting the victim is what turns a hit near an edge
## into a fall.
@export var knockback_up : float = 0.0

func _ready() -> void:
	_update_disabled()

func set_disabled(_disabled: bool) -> void:
	if disabled != _disabled:
		disabled = _disabled
		_update_disabled()

func _update_disabled() -> void:
	for child in get_children():
		if child is CollisionShape2D or child is CollisionPolygon2D:
			child.set_deferred("disabled", disabled)

func _on_body_entered(body: Node) -> void:
	if not disabled and body.has_method('hurt'):
		if not GameState.online_play or body.is_multiplayer_authority():
			# A hitbox with no knockback configured takes exactly the path it
			# always took.
			if knockback <= 0.0 and knockback_up <= 0.0:
				body.hurt(self)
				return

			# Otherwise sample the victim's state around the call, so the shove
			# lands once per hit and only when the hit actually landed. hurt()
			# silently declines in several cases -- an invincible player, one
			# already Hurt or Dead, one holding this very weapon -- and knocking
			# those victims about anyway would be a shove with no damage behind
			# it.
			var before := _victim_state(body)
			body.hurt(self)
			if before != "Hurt" and _victim_state(body) == "Hurt":
				_apply_knockback(body)

func _victim_state(body: Node) -> String:
	var machine = body.get("state_machine")
	if machine == null or machine.current_state == null:
		return ""
	return str(machine.current_state.name)

func _apply_knockback(body: Node) -> void:
	var victim := body as Node2D
	if victim == null:
		return

	var offset := victim.global_position - global_position
	# Straight-down hits (offset.x == 0) still have to go somewhere; keep the
	# victim moving the way this hitbox is travelling rather than dropping the
	# shove entirely.
	var direction := signf(offset.x)
	if is_zero_approx(direction):
		direction = signf(global_transform.x.x)
	if is_zero_approx(direction):
		direction = 1.0

	# Added to the vector hurt() just set, so the small push_back is kept and
	# this is felt as extra force rather than as a replacement.
	victim.set("vector", victim.get("vector") + Vector2(direction * knockback, -knockback_up))
