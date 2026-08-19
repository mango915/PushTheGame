extends Pickup

# The sword has no numbers of its own: everything tunable about it (where the
# player carries it, how much a thrown sword bounces) lives in the shared block
# of its WeaponData, which Pickup._apply_weapon_data() applies. See
# resources/sword_weapon.tres.

@onready var animation_player = $AnimationPlayer
@onready var sounds = $Sounds

func use() -> void:
	if animation_player.is_playing():
		return

	if not GameState.online_play:
		_do_use()
	else:
		rpc("_do_use")

func _on_throw() -> void:
	if animation_player.is_playing() and animation_player.current_animation != "Reset":
		animation_player.play("Reset")

@rpc("any_peer", "call_local") func _do_use() -> void:
	animation_player.play("Swing")
	sounds.play("Swing")
