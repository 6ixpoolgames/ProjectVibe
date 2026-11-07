## Written by Claude (claude-opus-5-5), 2026-11-06: runs streaming_sample.tscn. A test pawn walks a big loop by following
## nav paths, and chunks load ahead of it and unload behind it. Yellow lines mark the loaded chunks, and the blue line is
## the nav path it's following. Press L to pretend the CPU is 3 times slower. Nothing else uses this script.
extends Node3D

## Corners of the loop the pawn walks, in metres. It's made big so that it crosses many chunks.
const LOOP: Array[Vector2] = [Vector2(40, 40), Vector2(900, 40), Vector2(900, 900), Vector2(40, 900)]
## How far ahead to plan each path, in metres. It has to be well inside the source's nav_distance.
const PLAN_AHEAD := 48.0
const CAMERA_OFFSET := Vector3(0.0, 620.0, 540.0)

# GDScript note: $Name finds a child node by its name. @onready waits until the node is ready, when children exist.
@onready var _terrain: Terrain = $Terrain
@onready var _streamer: SlowChunkStreamer = $ChunkStreamer # Claude 2026-11-07: the test version, for the slower-CPU key
@onready var _camera: Camera3D = $Camera
@onready var _label: Label = $Display/Label

var _pawn: StreamingSamplePawn
var _next_corner := 1
var _chunk_lines := MeshInstance3D.new()
var _path_lines := MeshInstance3D.new()
var _chunks_changed := true


func _ready() -> void:
	_pawn = StreamingSamplePawn.new()
	_pawn.terrain = _terrain
	_pawn.speed = 20.0
	_pawn.position = Vector3(LOOP[0].x, 60.0, LOOP[0].y)
	add_child(_pawn)
	_pawn.source.nav_distance = 96.0

	# A red capsule, far larger than the pawn itself, so it shows up from the camera's height.
	var marker := MeshInstance3D.new()
	var marker_mesh := CapsuleMesh.new()
	marker_mesh.radius = 7.0
	marker_mesh.height = 26.0
	marker.mesh = marker_mesh
	marker.position.y = 13.0
	marker.material_override = _line_material(Color(0.9, 0.15, 0.1))
	_pawn.add_child(marker)

	for lines in [_chunk_lines, _path_lines]:
		lines.mesh = ImmediateMesh.new()
		add_child(lines)
	_chunk_lines.material_override = _line_material(Color(1.0, 0.85, 0.2))
	_path_lines.material_override = _line_material(Color(0.2, 0.75, 1.0))

	# GDScript note: this connects both signals to one small function that ignores which chunk changed.
	var mark_changed := func(_key: Vector2i) -> void: _chunks_changed = true
	_streamer.chunk_loaded.connect(mark_changed)
	_streamer.chunk_unloaded.connect(mark_changed)


func _physics_process(_delta: float) -> void:
	if _pawn.finished_route or _pawn.route.is_empty():
		_plan_next_path()


func _process(_delta: float) -> void:
	_camera.global_position = _pawn.global_position + CAMERA_OFFSET
	_camera.look_at(_pawn.global_position)
	if _chunks_changed:
		_chunks_changed = false
		_draw_chunk_outlines()
	_update_label()


# GDScript note: _unhandled_key_input is called for key presses that nothing else used.
func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_pressed() and not event.is_echo() and (event as InputEventKey).physical_keycode == KEY_L:
		_streamer.simulate_slower_cpu = 3.0 if _streamer.simulate_slower_cpu == 1.0 else 1.0
		_streamer.reset_worst_times()


## Plans the next stretch toward the current corner of the loop, using nav if it's ready there.
func _plan_next_path() -> void:
	var here := Vector2(_pawn.global_position.x, _pawn.global_position.z)
	if here.distance_to(LOOP[_next_corner]) < 8.0:
		_next_corner = (_next_corner + 1) % LOOP.size()
	var flat_target := here + (LOOP[_next_corner] - here).limit_length(PLAN_AHEAD)
	var target := Vector3(flat_target.x, _terrain.height_at(flat_target.x, flat_target.y), flat_target.y)
	var path := NavServer.find_path_now(_pawn.global_position, target, 0)
	# If nav isn't ready there yet, the pawn waits and the next tick tries again.
	if path.size() >= 2:
		_pawn.set_route(path)
		_draw_path(path)


func _draw_chunk_outlines() -> void:
	var mesh: ImmediateMesh = _chunk_lines.mesh
	mesh.clear_surfaces()
	var chunks := _terrain.get_loaded_chunks()
	if chunks.is_empty():
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var size := _terrain.chunk_size
	for key in chunks:
		var start := Vector2(key.x * size, key.y * size)
		# Two sides are enough for each chunk: its neighbours draw the others.
		_add_ground_line(mesh, start, start + Vector2(size, 0.0))
		_add_ground_line(mesh, start, start + Vector2(0.0, size))
	mesh.surface_end()


## Draws a line along the ground, in short pieces so that it follows the hills.
func _add_ground_line(mesh: ImmediateMesh, from: Vector2, to: Vector2) -> void:
	const PIECES := 8
	for i in PIECES:
		var a := from.lerp(to, float(i) / PIECES)
		var b := from.lerp(to, float(i + 1) / PIECES)
		mesh.surface_add_vertex(Vector3(a.x, _terrain.height_at(a.x, a.y) + 1.5, a.y))
		mesh.surface_add_vertex(Vector3(b.x, _terrain.height_at(b.x, b.y) + 1.5, b.y))


func _draw_path(path: PackedVector3Array) -> void:
	var mesh: ImmediateMesh = _path_lines.mesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(1, path.size()):
		mesh.surface_add_vertex(path[i - 1] + Vector3.UP * 3.0)
		mesh.surface_add_vertex(path[i] + Vector3.UP * 3.0)
	mesh.surface_end()


func _update_label() -> void:
	var stats := _streamer.get_stats()
	var nav_stats: Dictionary = NavServer.get_stats()
	var lines := PackedStringArray()
	lines.append("chunks loaded: %d    waiting: %d    loaded so far: %d    unloaded so far: %d" % [_terrain.get_loaded_chunks().size(), stats.queued, stats.total_loaded, stats.total_unloaded])
	lines.append("streaming this frame: %.2f ms    worst frame: %.2f ms    worst step: %.2f ms" % [stats.last_frame_ms, stats.worst_frame_ms, stats.worst_step_ms])
	lines.append("nav tiles: %d    still building: %d" % [nav_stats.live_detour_tiles, nav_stats.queued + nav_stats.dirty + nav_stats.building])
	lines.append("L: pretend the CPU is slower (now x%d)    frame rate: %d" % [int(_streamer.simulate_slower_cpu), Engine.get_frames_per_second()])
	_label.text = "\n".join(lines)


func _line_material(color: Color) -> StandardMaterial3D:
	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.albedo_color = color
	return line_material
