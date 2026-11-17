# Written by Claude (claude-opus-5-5), 2026-11-17. History: navigation/CHANGELOG.md.
## Puts a static body (a wall, a rock, a building) into the nav mesh.
##
## Add it as a child of a StaticBody3D, the way [TerrainNavFeeder] puts the terrain in. Its box shapes go into nav when it enters the
## tree and come out when it leaves; other shapes are skipped with a warning. Pawns then plan paths around the body, and a pawn walking
## the nav mesh (CrowdMover's C++ batch, NavWalking) slides along it instead of being handed to physics. Without it, paths go straight
## through the body and only physics stops the pawn. After moving the body by code, call [method refresh].
class_name BodyNavFeeder
extends Node

# Every feeder's boxes go into one shared input layer, each body as its own mesh, so a level with many props doesn't add a layer per prop
# (every tile build goes through every layer). Static: shared by every feeder.
static var _layer := -1

var _body: StaticBody3D = null
var _submitted := false


func _ready() -> void:
	_body = get_parent() as StaticBody3D
	if _body == null:
		push_warning("BodyNavFeeder: its parent isn't a StaticBody3D, so nav doesn't see it.")
		return
	refresh()


func _exit_tree() -> void:
	var nav := _get_nav()
	if nav and _submitted:
		nav.remove_mesh(_layer, _mesh_id())
	_submitted = false


## Sends the body's boxes to nav again, from where the body is now. The nav tiles under it rebuild over the next few ticks.
func refresh() -> void:
	var nav := _get_nav()
	if nav == null or _body == null:
		return
	if _layer < 0:
		var adapter := ClassDB.class_get_integer_constant(&"NavServer", &"ADAPTER_MESH")
		_layer = nav.add_input_layer(null, NavHooks.new(), adapter) # NavHooks' defaults: solid added, like the ground
	var faces := PackedVector3Array()
	for child in _body.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.disabled or shape_node.shape == null:
			continue
		var box := shape_node.shape as BoxShape3D
		if box == null:
			push_warning("BodyNavFeeder: %s isn't a box, so nav leaves it out." % shape_node.get_path())
			continue
		faces.append_array(box_faces(shape_node.transform, box.size))
	if faces.is_empty():
		return
	# The faces are in the body's own space, and nav is told where the body is.
	nav.submit_mesh(_layer, _mesh_id(), faces, _body.global_transform)
	_submitted = true


## The 12 triangles of a box of this size, placed by the shape's transform. Each side is wound to face out (clockwise seen from outside,
## as Godot draws front faces), so nav takes the top as ground and the sides as walls.
static func box_faces(shape_transform: Transform3D, size: Vector3) -> PackedVector3Array:
	var lo := -size * 0.5
	var hi := size * 0.5
	var corners := [
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
	]
	var quads := [[3, 2, 1, 0], [4, 5, 6, 7], [1, 5, 4, 0], [2, 6, 5, 1], [3, 7, 6, 2], [0, 4, 7, 3]]
	var faces := PackedVector3Array()
	for q in quads:
		var a: Vector3 = shape_transform * corners[q[0]]
		var b: Vector3 = shape_transform * corners[q[1]]
		var c: Vector3 = shape_transform * corners[q[2]]
		var d: Vector3 = shape_transform * corners[q[3]]
		faces.append_array([a, b, c, a, c, d])
	return faces


# Nav knows each mesh in a layer by one number; the body's instance id is unique while it lives.
func _mesh_id() -> int:
	return _body.get_instance_id()


# The NavServer singleton, or null without the C++ library. Untyped, because the class only exists when the library loads.
static func _get_nav() -> Object:
	return Engine.get_singleton(&"NavServer") if Engine.has_singleton(&"NavServer") else null
