extends Button

@onready var original_modulate = modulate

@export var transparency : float = 0.75

func _ready() -> void:
	self.mouse_entered.connect(Callable(self, "_on_mouse_entered"))
	self.mouse_exited.connect(Callable(self, "_on_mouse_exited"))
	_on_mouse_exited()

func _on_mouse_entered() -> void:
	modulate = original_modulate

func _on_mouse_exited() -> void:
	modulate.a = transparency
