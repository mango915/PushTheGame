extends Node

@export var cross_fade_duration: float = 2.0

signal song_finished (song)

#@onready var tween = $Tween

var current_song
var initial_volume_dbs := {}

func _ready() -> void:
	for child in get_children():
		if child is AudioStreamPlayer:
			initial_volume_dbs[child.name] = child.volume_db
			child.finished.connect(Callable(self, "_on_song_finished").bind(child))

func play(song_name: String) -> void:

	var next_song = get_node(song_name)
	if !next_song or next_song.playing:
		return
	
	var tween = get_tree().create_tween()
	if current_song:
		tween.tween_property(current_song, "volume_db", current_song.volume_db, -40.0).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	
	next_song.play()
	tween.tween_property(next_song, "volume_db", -40.0, initial_volume_dbs.get(next_song.name, 0.0)).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	
	current_song = next_song
	tween.play()

func play_random() -> void:
	if get_child_count() == 1:
		return

	var next_song: Node
	while next_song == null or current_song == next_song:
		next_song = _pick_random()
	
	play(next_song.name)

func _pick_random() -> Node:
	return get_child(randi() % (get_child_count() - 1))

func _on_song_finished(song) -> void:
	emit_signal("song_finished", song)

func _on_Tween_tween_completed(object: Object, key: NodePath) -> void:
	if object != current_song:
		object.stop()

