extends Pickup

# The sword has no numbers of its own: everything tunable about it (where the
# player carries it, how much a thrown sword bounces) lives in the shared block
# of its WeaponData, which Pickup._apply_weapon_data() applies. See
# resources/sword_weapon.tres.

@onready var animation_player = $AnimationPlayer
@onready var sounds = $Sounds
# Sword.tscn's Hitbox (components/Hitbox.gd). Its `disabled` flag is normally
# keyed by the animations; _on_throw() has to put it back by hand.
@onready var hitbox = get_node_or_null("Hitbox")

func use() -> void:
	if animation_player.is_playing():
		return

	if not GameState.online_play:
		_do_use()
	else:
		rpc("_do_use")

func _on_throw() -> void:
	# Sword.tscn only defines "Idle" and "Swing" -- there is no "Reset"
	# animation, so the old play("Reset") raised an error and left "Swing"
	# running. A sword thrown during Swing's 0.1s-0.2s window therefore kept its
	# hitbox enabled and killed whatever it touched, while a sword thrown at any
	# other moment was harmless: the damage of a thrown sword was pure timing
	# luck. Cancel the swing and force the hitbox back to its idle state.
	#
	# The .tscn is a shared asset and cannot gain a "Reset" animation here, so
	# the reset is done in code. "Idle" keys Hitbox:disabled = true and
	# Sprite2D:frame = 0, but an AnimationPlayer only applies its keys on its
	# next update, so the hitbox is also disabled explicitly -- a thrown sword
	# must be inert on the very frame it leaves the hand.
	if animation_player.is_playing():
		animation_player.stop()
	animation_player.play("Idle")

	if hitbox != null:
		hitbox.disabled = true

@rpc("any_peer", "call_local") func _do_use() -> void:
	animation_player.play("Swing")
	sounds.play("Swing")
	_swing_visual()

# The Scribble sword is a single sprite -- the frame track that used to draw the
# arc is gone with the rest of the pixel art -- so the swing is a rotation.
#
# Deliberately separate from the AnimationPlayer, which still owns the Hitbox
# timing: the hitbox is what decides who dies, and it should not be coupled to a
# cosmetic tween that a slow frame could stretch.
const SWING_ARC := 2.2
const SWING_SECONDS := 0.18

func _swing_visual() -> void:
	var sprite := get_node_or_null("Sprite2D") as Node2D
	if sprite == null:
		return
	var facing := -1.0 if scale.x < 0.0 else 1.0
	sprite.rotation = -SWING_ARC * 0.35 * facing
	var tween := create_tween()
	tween.tween_property(sprite, "rotation", SWING_ARC * 0.65 * facing, SWING_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "rotation", 0.0, SWING_SECONDS * 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
