# Written by Claude (claude-opus-5-5), 2026-11-04. History: netcode/CHANGELOG.md.
## The server checking a late attack against what the shooter saw (netcode spec section 9).
##
## A client draws other players in the past, so when its attack reaches the server the target has moved on. These checks move everyone
## else back to where the shooter saw them, test the hit, and put them back. Authority only, attacks only, inside a tick; movement is
## never rewound. With no time to go back (AI swings, offline play, lag compensation off) nothing is rewound.
## [codeblock]
## var hit := LagCompensation.hitscan(shooter_entity, origin, direction, 50.0, view_ticks_behind)
## [/codeblock]
## Design: netcode spec 9.
class_name LagCompensation
extends RefCounted


## A ray from origin along direction. Returns {} for no hit, else {"position", "collider", "entity": NetworkEntity or null}.
## [br]A wall in the way blocks it, because the world doesn't rewind.
static func hitscan(shooter: NetworkEntity, origin: Vector3, direction: Vector3, length: float, view_ticks_behind: float) -> Dictionary:
	var body := shooter.get_parent() as Node3D
	if body == null:
		return {}
	var rewound := _rewind_others(shooter, view_ticks_behind)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction.normalized() * length)
	if body is CollisionObject3D:
		query.exclude = [body.get_rid()]
	var hit: Dictionary = body.get_world_3d().direct_space_state.intersect_ray(query)
	_restore(rewound)
	if hit.is_empty():
		return {}
	return {"position": hit["position"], "collider": hit["collider"], "entity": _entity_of(hit["collider"])}


## A sphere around centre, such as a melee swing. Returns every entity it touched, as an Array of NetworkEntity.
static func melee(shooter: NetworkEntity, centre: Vector3, radius: float, view_ticks_behind: float) -> Array[NetworkEntity]:
	# One sphere is a list of one, checked by melee_spheres.
	var one: Array[Vector3] = [centre]
	return melee_spheres(shooter, one, radius, view_ticks_behind)


## Several spheres of one radius (such as a sweeping swing's spots in one tick), checked in one rewind. Returns each entity touched once.
static func melee_spheres(shooter: NetworkEntity, centres: Array[Vector3], radius: float, view_ticks_behind: float) -> Array[NetworkEntity]:
	var found: Array[NetworkEntity] = []
	var body := shooter.get_parent() as Node3D
	if body == null or centres.is_empty():
		return found
	var rewound := _rewind_others(shooter, view_ticks_behind)
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	if body is CollisionObject3D:
		query.exclude = [body.get_rid()]
	var space := body.get_world_3d().direct_space_state
	for centre in centres:
		query.transform = Transform3D(Basis.IDENTITY, centre)
		for hit: Dictionary in space.intersect_shape(query):
			var entity := _entity_of(hit["collider"])
			if entity and not found.has(entity):
				found.append(entity)
	_restore(rewound)
	return found


## True if a check for this shooter would move other entities back first; if not, it can use where pawns are now (as MeleeSweepStep does).
static func would_rewind(shooter: NetworkEntity, view_ticks_behind: float) -> bool:
	return _ticks_to_rewind(shooter, view_ticks_behind) > 0.0


# Ticks back the shooter's view is, limited to [0, rewind_cap_seconds] and to what its snapshot ACKs make believable (the server never trusts the claim).
static func _ticks_to_rewind(shooter: NetworkEntity, view_ticks_behind: float) -> float:
	var session: Node = shooter.session
	if session == null or not session.lag_compensation_enabled:
		return 0.0
	var driver: Node = shooter.get_node_or_null("/root/TickDriver")
	if driver == null:
		return 0.0
	var cap: float = session.rewind_cap_seconds * driver.get_tick_rate()
	var believable: float = session.limit_view_ticks_behind(shooter.owner_peer, view_ticks_behind, driver.tick)
	return clampf(believable, 0.0, cap)


static func _rewind_others(shooter: NetworkEntity, view_ticks_behind: float) -> Array[NetworkEntity]:
	var rewound: Array[NetworkEntity] = []
	# Nothing to go back: skip, rather than rewinding every entity to the present.
	var back := _ticks_to_rewind(shooter, view_ticks_behind)
	if back <= 0.0:
		return rewound
	var driver: Node = shooter.get_node_or_null("/root/TickDriver")
	var session: Node = shooter.session
	var view_tick: float = driver.tick - back
	for entity: NetworkEntity in session.get_entities():
		if entity != shooter and entity.rewind_to(view_tick):
			rewound.append(entity)
	return rewound


static func _restore(rewound: Array[NetworkEntity]) -> void:
	for entity: NetworkEntity in rewound:
		if is_instance_valid(entity):
			entity.restore_after_rewind()


static func _entity_of(collider: Object) -> NetworkEntity:
	if collider and collider.has_meta(&"network_entity"):
		return collider.get_meta(&"network_entity") as NetworkEntity
	return null
