extends Node

# Guards Game._pick_next_map().
#
# Map choice is easy to get subtly wrong in both directions. Pure random repeats
# maps and can serve the same arena three rounds running; a strict
# (map_index + 1) % size never repeats but makes the whole session one
# predictable loop, which with three arenas players read immediately. The bag
# has to give every arena an outing per cycle AND never repeat back to back --
# including across the seam where one cycle refills into the next, which is the
# case a naive shuffle gets wrong roughly one time in three.

const GameScene := preload("res://Game.tscn")

var _failures := 0

func _check(label: String, actual, expected) -> void:
	if actual == expected:
		print("[rot] OK: %s" % label)
	else:
		_failures += 1
		print("[rot] FAIL: %s (expected %s, got %s)" % [label, str(expected), str(actual)])

func _check_true(label: String, actual: bool) -> void:
	_check(label, actual, true)

func _ready() -> void:
	print("[rot] starting")
	randomize()

	_check_covers_every_arena()
	_check_never_repeats()
	_check_single_map()

	print("[rot] %d assertion(s) failed" % _failures)
	get_tree().quit(0)

# Draws `count` maps the way a real session does: pick, then load, then pick.
func _draw(game: Node, count: int) -> Array:
	var drawn := []
	for i in range(count):
		var next: int = game._pick_next_map()
		game.map_index = next
		drawn.append(next)
	return drawn

func _make_game() -> Node:
	var game = GameScene.instantiate()
	add_child(game)
	return game

func _check_covers_every_arena() -> void:
	var game := _make_game()
	var size: int = game.map_scenes.size()
	_check_true("the pool has more than one arena", size > 1)

	# Two full cycles: each arena should come up exactly twice.
	var drawn := _draw(game, size * 2)
	var counts := {}
	for index in drawn:
		counts[index] = int(counts.get(index, 0)) + 1

	_check("two cycles draw two of each", counts.size(), size)
	var even := true
	for index in counts:
		if counts[index] != 2:
			even = false
	_check_true("every arena appears exactly twice in two cycles (%s)" % [counts], even)

	game.queue_free()

func _check_never_repeats() -> void:
	# Run it hard: the failure this is really looking for is the seam between one
	# emptied bag and the next refill, which only bites on some shuffles.
	var repeats := 0
	for attempt in range(40):
		var game := _make_game()
		var drawn := _draw(game, 24)
		for i in range(1, drawn.size()):
			if drawn[i] == drawn[i - 1]:
				repeats += 1
		game.queue_free()
	_check("no arena is ever drawn twice in a row (960 draws)", repeats, 0)

func _check_single_map() -> void:
	# A one-map pool has no choice to make and must not spin looking for one.
	var game := _make_game()
	# Typed to match the export (Array[PackedScene]). Assigning a plain Array
	# raises "Invalid set index" and aborts this function mid-way -- which left
	# the assertion below unrun while the suite still reported zero failures.
	var single: Array[PackedScene] = [game.map_scenes[0]]
	game.map_scenes = single
	var drawn := _draw(game, 5)
	_check("a single-arena pool keeps returning it", drawn, [0, 0, 0, 0, 0])
	game.queue_free()
