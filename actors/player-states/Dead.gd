extends "res://addons/snopek-state-machine/State.gd"

@onready var host = $"../.."

func _state_enter(info: Dictionary) -> void:
	# The explosion effect is spawned by Player._do_die(), which is an
	# @rpc(..., "call_local") method and so runs on every peer.
	host.die()
