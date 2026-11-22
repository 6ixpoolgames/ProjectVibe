# Written by Claude (claude-opus-5-5), 2026-11-22. History: abilities/CHANGELOG.md.
## Which pawns a hit volume touches this tick: one question for a swing's sweep and a projectile's flight (ability spec 13.1).
##
## Spheres of one radius along a path (no more than half a radius apart, so nothing is skipped) against the pawns' capsules, nearest the
## path's start first. Inside: the C++ pawn grid, physics without it, and lag compensation when the attacker saw other pawns in the past.
## The history query and one batched call a tick for every volume come in here later, so melee and projectiles get them at once.
class_name HitQuery
extends RefCounted


static var _query: PhysicsShapeQueryParameters3D = null # the physics fallback's, kept between calls


## The pawns these spheres touch on this tick, nearest the first centre first. The attacker is left out unless include_attacker. With
## view_ticks_behind above 0 and a session, as the attacker saw them (lag compensation).
static func touching(centres: PackedVector3Array, radius: float, tick: int, attacker: Pawn, view_ticks_behind := 0.0,
		include_attacker := false) -> Array[Pawn]:
	var found: Array = []
	if centres.is_empty():
		return []
	var leave_out: Pawn = null if include_attacker else attacker
	var entity: NetworkEntity = attacker.get_network_entity() if attacker else null
	if view_ticks_behind > 0.0 and entity and entity.session and LagCompensation.would_rewind(entity, view_ticks_behind):
		var spheres: Array[Vector3] = []
		spheres.assign(centres)
		for touched in LagCompensation.melee_spheres(entity, spheres, radius, view_ticks_behind):
			found.append(touched.get_parent())
	elif SharedPawnTable.get_grid() != null and attacker and attacker.is_inside_tree():
		found = SharedPawnTable.get_grid().find_touching(centres, radius, leave_out, tick)
	else:
		found = _plain_spheres(centres, radius, leave_out, attacker)
	var out: Array[Pawn] = []
	var along_of := {}
	var start := centres[0]
	var path := centres[centres.size() - 1] - start
	for thing: Object in found:
		var pawn := thing as Pawn
		if pawn == null or (pawn == attacker and not include_attacker) or along_of.has(pawn):
			continue
		along_of[pawn] = (pawn.global_position - start).dot(path)
		out.append(pawn)
	if out.size() > 1:
		out.sort_custom(func(a: Pawn, b: Pawn) -> bool: return along_of[a] < along_of[b])
	return out


## Spheres of this radius along the line start -> end, no more than half a radius apart so nothing between them is skipped: the
## centres for [method touching] for a projectile's flight or a hitscan line.
static func line_centres(start: Vector3, end: Vector3, radius: float) -> PackedVector3Array:
	var spots := maxi(1, ceili(start.distance_to(end) / maxf(radius * 0.5, 0.01)))
	var centres := PackedVector3Array()
	centres.resize(spots + 1)
	for i in spots + 1:
		centres[i] = start.lerp(end, float(i) / spots)
	return centres


## The point on the path start -> end nearest a pawn: where a hit on it is placed.
static func point_on_path(start: Vector3, end: Vector3, pawn: Pawn) -> Vector3:
	var path := end - start
	var along := clampf((pawn.global_position - start).dot(path) / maxf(path.length_squared(), 0.000001), 0.0, 1.0)
	return start + path * along


# Without the C++ pawn grid, or outside the tree: the same spheres through physics, on the pawns' layer.
static func _plain_spheres(centres: PackedVector3Array, radius: float, leave_out: Pawn, near: Node3D) -> Array:
	var found: Array = []
	var world: World3D = near.get_world_3d() if near and near.is_inside_tree() else null
	if world == null:
		var tree := Engine.get_main_loop() as SceneTree
		world = tree.root.get_world_3d() if tree else null
	if world == null:
		return found
	if _query == null:
		_query = PhysicsShapeQueryParameters3D.new()
		_query.shape = SphereShape3D.new()
		_query.collision_mask = 2 # pawns are on layer 2 (pawn.tscn)
	var query := _query
	(query.shape as SphereShape3D).radius = radius
	query.exclude = [leave_out.get_rid()] if leave_out else []
	for centre in centres:
		query.transform = Transform3D(Basis.IDENTITY, centre)
		for hit in world.direct_space_state.intersect_shape(query, 8):
			if hit.collider is Pawn and not found.has(hit.collider):
				found.append(hit.collider)
	return found
