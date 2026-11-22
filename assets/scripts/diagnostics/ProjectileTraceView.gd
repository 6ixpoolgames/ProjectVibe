# Written by Claude (claude-opus-5-5), 2026-11-22, at the owner's request. History: diagnostics/CHANGELOG.md.
## A debug view of projectiles on F5: each one's planned path, where it has flown, what it met and where it ended.
##
## F5 shows and hides it in any level, through [DiagnosticsPanels], which makes it the first time. Debug builds only: in a release build
## it does nothing. For every projectile in flight it draws the path its launch record plans (dim), the part flown (bright), each
## intersect (a cross: green hit, grey met but not hit by the whitelist, orange the world) and where it ended (white). A trace stays
## [member keep_seconds] after its projectile is gone. Intersects are known where hits are decided (the server or offline); a client
## draws the paths. Hidden, it costs nothing. Design: ability spec 9.
class_name ProjectileTraceView
extends Node3D

## Shown or not; [method set_shown] changes it.
@export var shown := false
## Seconds a trace stays after its projectile is gone.
@export var keep_seconds := 3.0
## Points along a planned path.
@export var plan_points := 48

const PLAN_COLOR := Color(0.55, 0.65, 1.0, 0.35)
const FLOWN_COLOR := Color(1.0, 0.85, 0.3)
const HIT_COLOR := Color(0.3, 1.0, 0.4)
const MET_COLOR := Color(0.6, 0.6, 0.6)
const WORLD_COLOR := Color(1.0, 0.55, 0.1)
const END_COLOR := Color(1.0, 1.0, 1.0)
const MARK_SIZE := 0.25

# One trace per projectile seen: {"plan": PackedVector3Array, "flown": PackedVector3Array, "marks": [[point, colour]], "end": Vector3 or
# null, "gone_at": seconds or -1}.
var _traces := {}
var _mesh := ImmediateMesh.new()
var _view := MeshInstance3D.new()
var _material := StandardMaterial3D.new()
var _clock := 0.0


func _ready() -> void:
	top_level = true # world positions, wherever it's added
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = true # seen through walls, as a debug view should be
	_view.mesh = _mesh
	_view.material_override = _material
	add_child(_view)
	set_shown(shown)


## Shows or hides it. Debug builds only.
func set_shown(value: bool) -> void:
	shown = value and OS.is_debug_build()
	visible = shown
	set_process(shown)
	if not shown:
		_traces.clear()
		_mesh.clear_surfaces()


func _process(delta: float) -> void:
	_clock += delta
	for node in get_tree().get_nodes_in_group(Projectile.GROUP):
		var projectile := node as Projectile
		if projectile and projectile.launch_tick >= 0 and not _traces.has(projectile):
			_start_trace(projectile)
	for projectile: Variant in _traces.keys():
		var trace: Dictionary = _traces[projectile]
		if is_instance_valid(projectile):
			var at: Vector3 = (projectile as Projectile).global_position
			var flown: PackedVector3Array = trace.flown
			if flown.is_empty() or flown[flown.size() - 1].distance_squared_to(at) > 0.0004:
				flown.append(at)
				trace.flown = flown
		elif trace.gone_at < 0.0:
			trace.gone_at = _clock
		if trace.gone_at >= 0.0 and _clock - trace.gone_at > keep_seconds:
			_traces.erase(projectile)
	_draw()


func _start_trace(projectile: Projectile) -> void:
	# The path to the end worked out at launch (the world, range or lifetime), unless a pawn stops it first.
	var plan := PackedVector3Array()
	var ticks := maxi(projectile.end_tick, 1)
	for i in plan_points:
		plan.append(projectile.position_at(ticks * float(i) / plan_points))
	plan.append(projectile.end_point)
	var trace := {"plan": plan, "flown": PackedVector3Array([projectile.launch_origin]), "marks": [], "end": null, "gone_at": -1.0}
	_traces[projectile] = trace
	projectile.intersected.connect(func(_p: Projectile, entry: Dictionary) -> void:
		var colour := WORLD_COLOR if entry.kind == HitRun.Kind.WORLD else (HIT_COLOR if entry.hit else MET_COLOR)
		trace.marks.append([entry.point, colour]))
	projectile.ended.connect(func(_p: Projectile, at: Vector3) -> void: trace.end = at)


func _draw() -> void:
	_mesh.clear_surfaces()
	if _traces.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for trace: Dictionary in _traces.values():
		var fade := 1.0
		if trace.gone_at >= 0.0:
			fade = clampf(1.0 - (_clock - trace.gone_at) / maxf(keep_seconds, 0.01), 0.0, 1.0)
		_polyline(trace.plan, _faded(PLAN_COLOR, fade))
		_polyline(trace.flown, _faded(FLOWN_COLOR, fade))
		for mark: Array in trace.marks:
			_cross(mark[0], _faded(mark[1], fade))
		if trace.end != null:
			_cross(trace.end, _faded(END_COLOR, fade))
	_mesh.surface_end()


func _polyline(points: PackedVector3Array, colour: Color) -> void:
	for i in range(1, points.size()):
		_mesh.surface_set_color(colour)
		_mesh.surface_add_vertex(points[i - 1])
		_mesh.surface_set_color(colour)
		_mesh.surface_add_vertex(points[i])


func _cross(at: Vector3, colour: Color) -> void:
	for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		_mesh.surface_set_color(colour)
		_mesh.surface_add_vertex(at - axis * MARK_SIZE)
		_mesh.surface_set_color(colour)
		_mesh.surface_add_vertex(at + axis * MARK_SIZE)


func _faded(colour: Color, fade: float) -> Color:
	return Color(colour.r, colour.g, colour.b, colour.a * fade)
