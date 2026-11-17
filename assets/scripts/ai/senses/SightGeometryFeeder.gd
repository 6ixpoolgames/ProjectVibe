# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Keeps the shared SightGeometry (line of sight in C++) fed with the solid things in the scene.
##
## With the geometry fed, line of sight can be tested off the main thread instead of with physics rays. On first use it finds every
## body in the tree, then follows the tree (a body entering or leaving, a collision shape added to or removed from a body); anything else
## the geometry notices itself, once a tick. So a designer only puts a prop on a layer in sight's sight_blocking_mask (layer 1 by
## default) and it blocks sight. Areas and pawns are left out. Never instanced: everything is static, so no autoload is needed.
## Design: scaling spec step 4.
class_name SightGeometryFeeder
extends RefCounted

## Off: no geometry, so sight casts physics rays on the main thread. Read when sight is first used; set it before pawns are made.
static var enabled := true

# The shared geometry, made on first use. Untyped, because the C++ class only exists when the library loads.
static var _geometry: Object = null


## The shared geometry, or null without the C++ library or with enabled off.
static func get_geometry() -> Object:
	if enabled and _geometry != null:
		return _geometry # already made: no need to ask the engine whether the class exists on every sight pass
	if not enabled or not ClassDB.class_exists(&"SightGeometry"):
		return null
	if _geometry == null:
		# A static function can't reach get_tree(), so it takes the running SceneTree from the engine.
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null:
			return null
		_geometry = ClassDB.instantiate(&"SightGeometry")
		_add_all(tree.root)
		# node_added and node_removed go out for every node entering or leaving the tree, anywhere.
		tree.node_added.connect(SightGeometryFeeder._on_node_added)
		tree.node_removed.connect(SightGeometryFeeder._on_node_removed)
	return _geometry


# True for what blocks sight: any collision object but areas and pawns.
static func _blocks_sight(node: Node) -> bool:
	return node is CollisionObject3D and not node is Area3D and not node is Pawn


static func _add_all(node: Node) -> void:
	if _blocks_sight(node):
		_geometry.add_body(node)
	for child in node.get_children():
		_add_all(child)


static func _on_node_added(node: Node) -> void:
	if _blocks_sight(node):
		_geometry.add_body(node)
	elif (node is CollisionShape3D or node is CollisionPolygon3D) and _blocks_sight(node.get_parent()):
		_geometry.mark_dirty(node.get_parent()) # its shapes are read again at the next sync


static func _on_node_removed(node: Node) -> void:
	if _blocks_sight(node):
		_geometry.remove_body(node)
	elif (node is CollisionShape3D or node is CollisionPolygon3D) and _blocks_sight(node.get_parent()):
		_geometry.mark_dirty(node.get_parent())
