## Written by Claude (claude-opus-5-5), 2026-11-03: click-to-test paths and terrain edits in the nav test scene.
## Left click: set start.  Right click: set goal.  1-4: clearance tier (pawn size class).
## Shift + left click: dig.  Ctrl + left click: raise.  The path re-requests itself when nav tiles change,
## so you can watch it reroute around (or through) your edits.
extends Node3D

@export var terrain: NavTestTerrain
@export var camera: Camera3D
@export var status_label: Label
@export var tier := 0

var _start: Variant = null
var _goal: Variant = null
var _request := -1
var _request_usec := 0
var _repath_pending := false
var _repath_timer := 0.0
var _line := MeshInstance3D.new()
var _line_mesh := ImmediateMesh.new()
var _start_marker := MeshInstance3D.new()
var _goal_marker := MeshInstance3D.new()


func _ready() -> void:
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.albedo_color = Color(1, 1, 1)
	line_mat.no_depth_test = true
	_line.material_override = line_mat
	_line.mesh = _line_mesh
	add_child(_line)
	_setup_marker(_start_marker, Color(0.2, 1, 0.3))
	_setup_marker(_goal_marker, Color(1, 0.25, 0.2))
	NavServer.path_ready.connect(_on_path_ready)
	NavServer.path_failed.connect(_on_path_failed)
	NavServer.tiles_changed.connect(func(_tiles): _repath_pending = true)
	_show_status("Left click: start   Right click: goal   1-4: tier   Shift/Ctrl+click: dig/raise   N: toggle nav")


func _setup_marker(marker: MeshInstance3D, colour: Color) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.mesh = sphere
	marker.material_override = mat
	marker.visible = false
	add_child(marker)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.physical_keycode
		if k >= KEY_1 and k <= KEY_4:
			tier = k - KEY_1
			_request_path()
		return
	if not (event is InputEventMouseButton and event.pressed):
		return
	var point: Variant = _pick(event.position)
	if point == null:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.shift_pressed:
			terrain.edit(point, 3.0, -1.5)
		elif event.ctrl_pressed:
			terrain.edit(point, 3.0, 1.5)
		else:
			_start = point
			_start_marker.position = point + Vector3.UP * 0.35
			_start_marker.visible = true
			_request_path()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_goal = point
		_goal_marker.position = point + Vector3.UP * 0.35
		_goal_marker.visible = true
		_request_path()


func _process(delta: float) -> void:
	# Re-request after nav changes, at most 5 times a second.
	_repath_timer += delta
	if _repath_pending and _repath_timer > 0.2:
		_repath_pending = false
		_repath_timer = 0.0
		_request_path()


func _pick(screen_pos: Vector2) -> Variant:
	if camera == null or terrain == null:
		return null
	return terrain.raycast(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))


func _request_path() -> void:
	if _start == null or _goal == null:
		return
	if _request >= 0:
		NavServer.cancel_path(_request)
	_request = NavServer.find_path(_start, _goal, tier)
	_request_usec = Time.get_ticks_usec()


func _on_path_ready(request_id: int, points: PackedVector3Array, partial: bool) -> void:
	if request_id != _request:
		return
	var ms := (Time.get_ticks_usec() - _request_usec) / 1000.0
	var length := 0.0
	for i in range(1, points.size()):
		length += points[i - 1].distance_to(points[i])
	_draw_path(points, Color(1, 0.6, 0.1) if partial else Color(1, 1, 1))
	_show_status("tier %d   %d corners   %.1f m   %s   (answered in %.1f ms, incl. waiting for next tick)" % [
		tier, points.size(), length, "PARTIAL (goal unreachable)" if partial else "ok", ms])


func _on_path_failed(request_id: int, reason: String) -> void:
	if request_id != _request:
		return
	_line_mesh.clear_surfaces()
	_show_status("tier %d   no path: %s" % [tier, reason])


func _draw_path(points: PackedVector3Array, colour: Color) -> void:
	_line_mesh.clear_surfaces()
	if points.size() < 2:
		return
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in points:
		_line_mesh.surface_set_color(colour)
		_line_mesh.surface_add_vertex(p + Vector3.UP * 0.25)
	_line_mesh.surface_end()


func _show_status(text: String) -> void:
	if status_label:
		status_label.text = text
