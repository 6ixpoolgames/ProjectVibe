## Written by Claude (claude-opus-5-5), 2026-11-09: keeps the shared SightGeometry (line of sight in C++, scaling spec step 4) fed with
## the solid things in the scene, so line of sight can be tested off the main thread instead of with physics rays.
##
## On first use it finds every body already in the tree, then follows the tree: a body entering is added, one leaving is removed, and
## a collision shape node added to or taken from a body marks that body to be read again. Everything else (a body moving, a shape's
## resource changing, a new collision layer) the geometry notices itself, once a tick. So a designer only puts a prop on a layer that
## sight's sight_blocking_mask includes (layer 1, the world, by default), and it blocks sight.
##
## What's left out: areas, which sight's rays never stopped at, and pawns, which move every tick. A sight sense whose mask includes
## the pawns' own layer keeps using physics rays, as before (AIMemoryStore.check_one).
##
## Not an autoload and never instanced: everything here is static (minimize autoloads), like TickJobs.
class_name SightGeometryFeeder
extends RefCounted

## Off: no geometry, so sight casts physics rays on the main thread, as before tier 1 step 4. Read when sight is first used; set it
## before pawns are made.
static var enabled := true

# The shared geometry, made on first use. Untyped, because the C++ class only exists when the library loads.
static var _geometry: Object = null


## The shared geometry, or null without the C++ library or with enabled off.
static func get_geometry() -> Object:
	if not enabled or not ClassDB.class_exists(&"SightGeometry"):
		return null
	if _geometry == null:
		# GDScript note: Engine.get_main_loop() is the running SceneTree, which a static function can't reach with get_tree().
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null:
			return null
		_geometry = ClassDB.instantiate(&"SightGeometry")
		_add_all(tree.root)
		# GDScript note: node_added and node_removed go out for every node entering or leaving the tree, anywhere.
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
