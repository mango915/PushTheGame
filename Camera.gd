extends Camera2D

@export var player_container_path: NodePath
@export var zoom_offset : float = 0.2
@export var custom_smoothing : float = 2.0

var player_container: Node2D

func _physics_process(delta: float) -> void:
	update_position_and_zoom()

func _center_position(pos: Vector2) -> Vector2:
	return pos - Vector2(0, 35)

func update_position_and_zoom(custom_smoothing_enabled: bool = true) -> void:
	if not player_container_path:
		return
	
	if not player_container:
		player_container = get_node(player_container_path)
		if not player_container:
			return
	
	# Only real players should frame the shot. Death explosions (CPUParticles2D)
	# are parented into the same container and must not drag the camera.
	var players := []
	for child in player_container.get_children():
		if child.has_method("pickup_or_throw"):
			players.append(child)

	var count := players.size()
	if count == 0:
		return

	var camera_rect := Rect2(_center_position(players[0].global_position), Vector2())
	for index in range(1, count):
		camera_rect = camera_rect.expand(_center_position(players[index].global_position))
	
	var viewport_rect = get_viewport_rect().size
	
	# If the camera_rect is shorter than the viewpoirt, ensure that it's 
	# positioned so that the bottom edge is just below the lowest character.
	var min_height = viewport_rect.y * (1.0 - zoom_offset)
	if camera_rect.size.y < min_height:
		var delta_height = min_height - camera_rect.size.y
		camera_rect.position.y -= delta_height
		camera_rect.size.y += delta_height
	
	var desired_global_position = calculate_center(camera_rect)
	var desired_zoom = calculate_zoom(camera_rect, get_viewport_rect().size)
	
	if custom_smoothing_enabled:
		var delta = get_physics_process_delta_time()
		global_position += (desired_global_position - global_position) * custom_smoothing * delta
		zoom += (desired_zoom - zoom) * custom_smoothing * delta
	else:
		global_position = desired_global_position
		zoom = desired_zoom

func calculate_center(camera_rect: Rect2) -> Vector2:
	return Vector2(
		camera_rect.position.x + (camera_rect.size.x / 2),
		camera_rect.position.y + (camera_rect.size.y / 2))

func calculate_zoom(camera_rect: Rect2, viewport_size: Vector2) -> Vector2:
	# In Godot 4 the visible area is viewport_size / zoom, so a LARGER zoom means
	# zoomed IN -- the inverse of Godot 3, where the visible area was
	# viewport_size * zoom. `span` is how many viewports wide/tall the players
	# span (plus the zoom_offset margin); inverting it makes the view widen as
	# the players spread apart. Clamped so we never zoom in past 1:1.
	var span: float = max(
		camera_rect.size.x / viewport_size.x,
		camera_rect.size.y / viewport_size.y) + zoom_offset
	var zoom_level: float = 1.0 / max(1.0, span)
	return Vector2(zoom_level, zoom_level)
	
