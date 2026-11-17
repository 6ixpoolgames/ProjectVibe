# Written by Claude (claude-opus-5-5), 2026-11-17, at the owner's request. History: navigation/CHANGELOG.md.
## A debug view of navigation: the live nav mesh, the nav links and the nav markers, on F9.
##
## F9 shows and hides it in any level, through [DiagnosticsPanels], which makes it the first time. Debug builds only: in a release
## build it does nothing. Around the camera (or [member follow]), [member radius] metres each way, it draws the nav mesh (coloured by
## how much room each triangle has, from [code]NavServer[/code]'s tiers), the nav links (arcs; cyan both ways, orange one way) and the
## nav markers (through [code]NavMarkerDebugModule[/code]). Hidden, it costs nothing. Without the C++ library only the markers show.
class_name NavDebugView
extends Node3D

## Shown or not; [method set_shown] changes it.
@export var shown := false
## The drawn area: this many metres each way from the centre.
@export var radius := 60.0
## The centre of the drawn area. Empty: the point on the ground plane the current camera looks at.
@export var follow: Node3D
## The least time between rebuilds of the drawing, in seconds. It rebuilds when nav tiles change or the centre moves a quarter of [member radius].
@export var rebuild_interval := 0.5

const LIFT := 0.08 # the nav mesh is drawn this far above the ground, so it doesn't flicker into it
const LINK_TWO_WAY_COLOR := Color(0.2, 0.9, 1.0)
const LINK_ONE_WAY_COLOR := Color(1.0, 0.55, 0.1)
const LINK_SEGMENTS := 10
const EDGE_COLOR := Color(0.05, 0.1, 0.25, 0.7)

var _nav: Object = null
var _mesh_view := MeshInstance3D.new()
var _edge_view := MeshInstance3D.new() # the triangles' outlines, so the mesh's shape reads against any ground
var _link_view := MeshInstance3D.new()
var _markers: NavMarkerDebugModule = null
var _needs_rebuild := true
var _seconds_since_rebuild := 0.0
var _drawn_centre := Vector3.INF
var _link_count := 0


func _ready() -> void:
	if not OS.is_debug_build():
		set_process(false)
		visible = false
		return
	if Engine.has_singleton(&"NavServer"):
		_nav = Engine.get_singleton(&"NavServer")
		# Only that something changed matters, not the tiles' list.
		_nav.tiles_changed.connect(func(_tiles: Variant) -> void: _needs_rebuild = true)
	var mesh_material := StandardMaterial3D.new()
	mesh_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_material.vertex_color_use_as_albedo = true
	mesh_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_material.albedo_color = Color(1, 1, 1, 0.55)
	mesh_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh_view.material_override = mesh_material
	_mesh_view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_view)
	var edge_material := StandardMaterial3D.new()
	edge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edge_material.albedo_color = EDGE_COLOR
	_edge_view.material_override = edge_material
	_edge_view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_edge_view)
	var link_material := StandardMaterial3D.new()
	link_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	link_material.vertex_color_use_as_albedo = true
	link_material.no_depth_test = true # links show through the ground and walls
	_link_view.material_override = link_material
	_link_view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_link_view)
	top_level = true # drawn in world space, wherever this node sits
	global_transform = Transform3D.IDENTITY
	_apply_shown()


## Shows or hides the view.
func set_shown(value: bool) -> void:
	shown = value and OS.is_debug_build()
	if is_node_ready() and OS.is_debug_build():
		_apply_shown()


func _apply_shown() -> void:
	visible = shown
	set_process(shown)
	if shown and _markers == null:
		_markers = NavMarkerDebugModule.new() # joins NavMarkerManager and is told about every marker already there
		add_child(_markers)
	elif not shown and _markers != null:
		_markers.queue_free()
		_markers = null
	if shown:
		_needs_rebuild = true
		_seconds_since_rebuild = rebuild_interval


# Running in _process breaks the usual tick rule on purpose: this only draws, so it can't affect gameplay.
func _process(delta: float) -> void:
	_seconds_since_rebuild += delta
	if _seconds_since_rebuild < rebuild_interval:
		return
	var centre := _centre()
	if not _needs_rebuild and Vector2(centre.x - _drawn_centre.x, centre.z - _drawn_centre.z).length() < radius * 0.25:
		return
	_seconds_since_rebuild = 0.0
	_needs_rebuild = false
	_drawn_centre = centre
	rebuild_now()


## Rebuilds the nav mesh and link drawing right away, around the current centre.
func rebuild_now() -> void:
	if _nav == null:
		return
	var centre := _centre()
	var area := AABB(Vector3(centre.x - radius, -10000.0, centre.z - radius), Vector3(radius * 2.0, 20000.0, radius * 2.0))
	_draw_nav_mesh(_nav.get_debug_triangles(area))
	_draw_links(_nav.get_debug_links(area))


## How many nav mesh triangles the current drawing holds.
func get_triangle_count() -> int:
	var mesh := _mesh_view.mesh as ArrayMesh
	@warning_ignore("integer_division") # whole numbers on purpose
	return mesh.surface_get_array_len(0) / 3 if mesh and mesh.get_surface_count() > 0 else 0


## How many links the current drawing shows.
func get_link_count() -> int:
	return _link_count


## The marker drawer while the view is shown, or null.
func get_marker_drawer() -> NavMarkerDebugModule:
	return _markers



func _centre() -> Vector3:
	if follow != null:
		return follow.get_focus() if follow.has_method(&"get_focus") else follow.global_position
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return Vector3.ZERO
	# A camera high above and tilted down looks at a spot far in front of it, so the centre is where its view line meets the
	# ground plane (y = 0), at most two radii ahead; a camera looking level or up uses the point under it.
	var forward := -camera.global_transform.basis.z
	var origin := camera.global_position
	if forward.y < -0.05:
		var along := -origin.y / forward.y
		return origin + forward * minf(along, radius * 2.0)
	return Vector3(origin.x, 0.0, origin.z)


func _draw_nav_mesh(data: Dictionary) -> void:
	var vertices: PackedVector3Array = data.get("vertices", PackedVector3Array())
	if vertices.is_empty():
		_mesh_view.mesh = null
		_edge_view.mesh = null
		return
	for i in vertices.size():
		vertices[i].y += LIFT
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX) # one slot per kind of data; most are unused here
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = data.get("colors", PackedColorArray())
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_view.mesh = mesh
	# Each triangle's three edges as lines, a little higher so they sit on top of the fill.
	var edges := PackedVector3Array()
	edges.resize(vertices.size() * 2)
	for i in range(0, vertices.size() - 2, 3):
		var a := vertices[i] + Vector3.UP * 0.01
		var b := vertices[i + 1] + Vector3.UP * 0.01
		var c := vertices[i + 2] + Vector3.UP * 0.01
		var at := i * 2
		edges[at] = a; edges[at + 1] = b
		edges[at + 2] = b; edges[at + 3] = c
		edges[at + 4] = c; edges[at + 5] = a
	var edge_arrays := []
	edge_arrays.resize(Mesh.ARRAY_MAX)
	edge_arrays[Mesh.ARRAY_VERTEX] = edges
	var edge_mesh := ArrayMesh.new()
	edge_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, edge_arrays)
	_edge_view.mesh = edge_mesh


func _draw_links(data: Dictionary) -> void:
	var starts: PackedVector3Array = data.get("starts", PackedVector3Array())
	var ends: PackedVector3Array = data.get("ends", PackedVector3Array())
	var two_way: PackedByteArray = data.get("two_way", PackedByteArray())
	_link_count = starts.size()
	if starts.is_empty():
		_link_view.mesh = null
		return
	var points := PackedVector3Array()
	var colors := PackedColorArray()
	for i in starts.size():
		var color := LINK_TWO_WAY_COLOR if two_way[i] else LINK_ONE_WAY_COLOR
		var from := starts[i]
		var to := ends[i]
		# An arc over the higher end, so a link reads as a jump or a drop rather than a line through the ground.
		var height := 0.5 + absf(to.y - from.y) * 0.5 + Vector2(to.x - from.x, to.z - from.z).length() * 0.15
		var previous := from
		for step in range(1, LINK_SEGMENTS + 1):
			var t := float(step) / LINK_SEGMENTS
			var point := from.lerp(to, t) + Vector3.UP * (4.0 * height * t * (1.0 - t)) # a parabola, 0 at each end
			points.append_array([previous, point])
			colors.append_array([color, color])
			previous = point
		if not two_way[i]:
			points.append_array([to, to + Vector3.UP * 0.6]) # a tick where a one-way link lands
			colors.append_array([color, color])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_link_view.mesh = mesh

