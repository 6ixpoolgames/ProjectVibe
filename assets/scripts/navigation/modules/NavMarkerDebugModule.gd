## Written by Claude (claude-opus-5-5), 2026-11-06: draws every nav marker while the game runs (nav spec section 21.4).
## Add this node to a level to see its markers, through walls and terrain. It does nothing in a release build.
##
## How markers look:
##   - Every marker is a small cross at its position, with a line showing which way it faces.
##   - A link also has a line from its start to its end.
##   - Areas and obstacles also have a box showing their size.
##   - Colours follow the type. A disabled marker is grey.
##
## It only looks at markers, so it doesn't count as handling them in the debug report. Otherwise, adding it
## would hide that nothing actually acts on them.
##
## The drawing is rebuilt from scratch when markers change, at most a few times a second. That's cheap at
## hundreds of markers. Past max_drawn it stops drawing the rest and warns once.
class_name NavMarkerDebugModule
extends NavMarkerModule

const LINK_COLOR := Color(0.2, 0.8, 1.0)
const AREA_COLOR := Color(0.3, 1.0, 0.4)
const OBSTACLE_COLOR := Color(1.0, 0.3, 0.25)
const SMART_OBJECT_COLOR := Color(1.0, 0.85, 0.2)
const POINT_COLOR := Color(1.0, 1.0, 1.0)
const OTHER_COLOR := Color(1.0, 0.4, 1.0) # a modder's own marker type, not based on any of the above
const DISABLED_COLOR := Color(0.45, 0.45, 0.45)
const FACING_LENGTH := 0.75

## The most markers to draw. The rest are skipped, because rebuilding the drawing gets slow.
@export var max_drawn := 20000
## The shortest time between rebuilds, in seconds.
@export var rebuild_interval := 0.25

var _ids := {}                  # the markers this module knows about, as id -> true
var _needs_rebuild := false
var _seconds_since_rebuild := 0.0
var _drawn_count := 0
var _warned_about_limit := false
var _mesh_instance: MeshInstance3D
# GDScript note: these two lists grow as lines are added, then become the mesh. Each line is two points in a row.
var _points := PackedVector3Array()
var _colors := PackedColorArray()


func handled_types() -> Array[Script]:
	# GDScript note: OS.is_debug_build() is true in the editor and debug exports, and false in release exports.
	if OS.is_debug_build():
		return [NavMarker]
	return []


func counts_for_report() -> bool:
	return false


func _ready() -> void:
	if not OS.is_debug_build():
		set_process(false)
		return
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = ArrayMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED # lines ignore lighting
	material.vertex_color_use_as_albedo = true # each line uses the colour stored in its points
	material.no_depth_test = true # drawn on top of everything, so markers show through terrain
	_mesh_instance.material_override = material
	add_child(_mesh_instance)


func _markers_added(ids: PackedInt64Array) -> void:
	for id in ids:
		_ids[id] = true
	_needs_rebuild = true


func _markers_changed(_changed_ids: PackedInt64Array) -> void:
	_needs_rebuild = true


func _markers_removed(ids: PackedInt64Array) -> void:
	for id in ids:
		_ids.erase(id)
	_needs_rebuild = true


# Running in _process breaks the usual tick rule on purpose. This only draws, so it can't affect gameplay.
func _process(delta: float) -> void:
	_seconds_since_rebuild += delta
	if _needs_rebuild and _seconds_since_rebuild >= rebuild_interval:
		rebuild_now()


## Rebuilds the drawing right away.
func rebuild_now() -> void:
	_needs_rebuild = false
	_seconds_since_rebuild = 0.0
	if _mesh_instance == null:
		return
	_points = PackedVector3Array()
	_colors = PackedColorArray()
	_drawn_count = 0
	# Sorted so that the same markers always draw the same way, and the limit always drops the same ones.
	var ids: Array = _ids.keys()
	ids.sort()
	for id: int in ids:
		if _drawn_count >= max_drawn:
			if not _warned_about_limit:
				_warned_about_limit = true
				push_warning("[NavMarkerDebugModule] drawing only %d of %d markers. Raise max_drawn to see more." % [max_drawn, ids.size()])
			break
		_draw_marker(id)
		_drawn_count += 1
	var mesh: ArrayMesh = _mesh_instance.mesh
	mesh.clear_surfaces()
	if _points.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX) # a surface is an array with one slot per kind of data, most of them unused here
	arrays[Mesh.ARRAY_VERTEX] = _points
	arrays[Mesh.ARRAY_COLOR] = _colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)


## How many markers the current drawing shows.
func get_drawn_count() -> int:
	return _drawn_count


## How many lines the current drawing holds.
func get_line_count() -> int:
	return _points.size() / 2


func _draw_marker(id: int) -> void:
	var marker := NavMarkerManager.get_marker(id)
	if marker == null:
		return
	var center := NavMarkerManager.get_marker_position(id)
	var color := _color_of(marker) if NavMarkerManager.is_marker_enabled(id) else DISABLED_COLOR
	_add_cross(center, marker.radius, color)
	_add_line(center, center + marker.facing * FACING_LENGTH, color)
	# GDScript note: "marker" is declared as a plain NavMarker, so each branch copies it into a variable of the
	# right type. That lets the editor check names like end_offset and offer them as suggestions.
	if marker is NavLink:
		var link: NavLink = marker
		_add_line(center, center + link.end_offset, color)
	elif marker is NavArea:
		var area: NavArea = marker
		_add_box(center, area.size, color)
	elif marker is NavObstacle:
		var obstacle: NavObstacle = marker
		_add_box(center, obstacle.size, color)


## The colour for a marker's type. Smart objects are checked before points because they are also points.
func _color_of(marker: NavMarker) -> Color:
	if marker is NavLink:
		return LINK_COLOR
	if marker is NavArea:
		return AREA_COLOR
	if marker is NavObstacle:
		return OBSTACLE_COLOR
	if marker is NavSmartObject:
		return SMART_OBJECT_COLOR
	if marker is NavPoint:
		return POINT_COLOR
	return OTHER_COLOR


func _add_line(from: Vector3, to: Vector3, color: Color) -> void:
	_points.append(from)
	_points.append(to)
	_colors.append(color)
	_colors.append(color)


func _add_cross(center: Vector3, size: float, color: Color) -> void:
	_add_line(center - Vector3(size, 0, 0), center + Vector3(size, 0, 0), color)
	_add_line(center - Vector3(0, size, 0), center + Vector3(0, size, 0), color)
	_add_line(center - Vector3(0, 0, size), center + Vector3(0, 0, size), color)


## The twelve edges of a box, centered on a position.
func _add_box(center: Vector3, size: Vector3, color: Color) -> void:
	var half := size / 2.0
	var corners: Array[Vector3] = []
	for x: float in [-half.x, half.x]:
		for y: float in [-half.y, half.y]:
			for z: float in [-half.z, half.z]:
				corners.append(center + Vector3(x, y, z))
	# Corners are numbered in the order above, so two corners share an edge when their numbers differ by one binary digit.
	for edge: Vector2i in [Vector2i(0, 1), Vector2i(2, 3), Vector2i(4, 5), Vector2i(6, 7), Vector2i(0, 2), Vector2i(1, 3),
			Vector2i(4, 6), Vector2i(5, 7), Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7)]:
		_add_line(corners[edge.x], corners[edge.y], color)
