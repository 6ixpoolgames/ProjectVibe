## Written by Claude (claude-opus-5-5), 2026-11-03: draws the live nav mesh (coloured by clearance tier) and tile states.
## Tier colours: blue = smallest pawns only, green = tier 1, yellow = tier 2, orange = room for the biggest.
## Tile outlines: grey queued, yellow building, green ready, orange dirty (rebuilding, old data still live),
## red failed, magenta provisional (a neighbour chunk was missing; rebuilt when it arrives).
## Toggle with N.
extends Node3D

@export var follow: Node3D ## centre of the drawn area (uses get_focus() if it has one)
@export var radius := 90.0

var _tris := MeshInstance3D.new()
var _lines := MeshInstance3D.new()
var _line_mesh := ImmediateMesh.new()
var _tris_dirty := true
var _timer := 0.0


func _ready() -> void:
	var tri_mat := StandardMaterial3D.new()
	tri_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tri_mat.vertex_color_use_as_albedo = true
	tri_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tri_mat.albedo_color = Color(1, 1, 1, 0.55)
	tri_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_tris.material_override = tri_mat
	add_child(_tris)

	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.vertex_color_use_as_albedo = true
	_lines.material_override = line_mat
	_lines.mesh = _line_mesh
	add_child(_lines)

	NavServer.tiles_changed.connect(func(_tiles): _tris_dirty = true)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.physical_keycode == KEY_N:
		visible = not visible


func _process(delta: float) -> void:
	if not visible:
		return
	_timer += delta
	if _timer < 0.2:
		return
	_timer = 0.0
	if _tris_dirty:
		_tris_dirty = false
		_rebuild_triangles()
	_rebuild_tile_outlines()


func _centre() -> Vector3:
	if follow == null:
		return Vector3.ZERO
	return follow.get_focus() if follow.has_method("get_focus") else follow.global_position


func _rebuild_triangles() -> void:
	var c := _centre()
	var area := AABB(Vector3(c.x - radius, -1000.0, c.z - radius), Vector3(radius * 2.0, 2000.0, radius * 2.0))
	var data: Dictionary = NavServer.get_debug_triangles(area)
	var verts: PackedVector3Array = data.vertices
	if verts.is_empty():
		_tris.mesh = null
		return
	for i in verts.size():
		verts[i].y += 0.06 # float just above the ground so it doesn't z-fight
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = data.colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_tris.mesh = mesh


func _rebuild_tile_outlines() -> void:
	var tw: float = NavServer.get_config().tile_world
	var colours := {
		"queued": Color(0.5, 0.5, 0.5), "building": Color(1, 0.9, 0.2), "ready": Color(0.2, 0.9, 0.3),
		"dirty": Color(1, 0.55, 0.1), "failed": Color(1, 0.1, 0.1),
	}
	var c := _centre()
	_line_mesh.clear_surfaces()
	var tiles: Array = NavServer.get_tile_states()
	if tiles.is_empty():
		return
	_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for t in tiles:
		var col: Color = Color(1, 0.2, 1) if t.provisional and t.state == "ready" else colours.get(t.state, Color.WHITE)
		var x0: float = t.tile.x * tw + 0.15
		var z0: float = t.tile.y * tw + 0.15
		var x1: float = x0 + tw - 0.3
		var z1: float = z0 + tw - 0.3
		var y := c.y + 0.5
		var corners := [Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1)]
		for i in 4:
			_line_mesh.surface_set_color(col)
			_line_mesh.surface_add_vertex(corners[i])
			_line_mesh.surface_set_color(col)
			_line_mesh.surface_add_vertex(corners[(i + 1) % 4])
	_line_mesh.surface_end()
