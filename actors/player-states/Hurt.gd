extends "res://addons/snopek-state-machine/State.gd"

@onready var host = $"../.."
@onready var timer = $Timer

func _state_enter(info: Dictionary) -> void:
	host.play_animation("Hurt")
	host.sounds.play("Hurt")
	var push_back_vector = info['push_back_vector'] if info.has("push_back_vector") else (Vector2.UP * host.push_back_speed)
	host.vector = push_back_vector
	# Remember which way we were hit, so the corpse this hurt turns into (the
	# timer below always ends in Dead) is flung away from the attacker. Recorded
	# here rather than in Player.hurt() because hurt() only ever runs on the
	# victim's own peer, while this state -- and the info dictionary carrying the
	# push-back -- is replicated to every peer.
	host.note_hit(push_back_vector)
	timer.start()

func _state_exit() -> void:
	timer.stop()

func _on_Timer_timeout() -> void:
	if host.state_machine.current_state == self:
		host.state_machine.change_state("Dead")
