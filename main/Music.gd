extends Node

@export var cross_fade_duration: float = 2.0

signal song_finished (song)

var current_song
var initial_volume_dbs := {}

func _ready() -> void:
	for child in get_children():
		if child is AudioStreamPlayer:
			initial_volume_dbs[child.name] = child.volume_db
			child.finished.connect(Callable(self, "_on_song_finished").bind(child))

func play(song_name: String) -> void:

	var next_song = get_node_or_null(song_name)
	if next_song == null or not (next_song is AudioStreamPlayer) or next_song.playing:
		return

	var previous_song = current_song

	# Both halves of the cross fade must run at the same time, otherwise the
	# tween would chain them and the fade would take 2 * cross_fade_duration.
	var tween = get_tree().create_tween().set_parallel(true)
	if previous_song:
		tween.tween_property(previous_song, "volume_db", -40.0, cross_fade_duration).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)

	# Start silent so there is something to fade up from.
	next_song.volume_db = -40.0
	next_song.play()
	tween.tween_property(next_song, "volume_db", initial_volume_dbs.get(next_song.name, 0.0), cross_fade_duration).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)

	current_song = next_song

	if previous_song:
		# Capture the outgoing player: current_song may have changed again by
		# the time the tween finishes.
		tween.finished.connect(_on_cross_fade_finished.bind(previous_song))

func play_random() -> void:
	var candidates := []
	for song in _songs():
		if song != current_song:
			candidates.append(song)

	if candidates.is_empty():
		return

	play(candidates[randi() % candidates.size()].name)

func _songs() -> Array:
	var songs := []
	for child in get_children():
		if child is AudioStreamPlayer:
			songs.append(child)
	return songs

func _pick_random():
	var songs := _songs()
	if songs.is_empty():
		return null
	return songs[randi() % songs.size()]

func _on_song_finished(song) -> void:
	emit_signal("song_finished", song)

func _on_cross_fade_finished(song) -> void:
	if is_instance_valid(song) and song != current_song:
		song.stop()

