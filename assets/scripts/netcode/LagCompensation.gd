## Written by Claude (claude-opus-5-5), 2026-11-04: the server checking a late attack against what the shooter saw
## (netcode spec section 9). A client draws other players in the past, so when its attack reaches the server, the target has
## moved on. The server moves everyone else back to where the shooter saw them, checks the hit, and puts them back.
##
## How far back: the client says how many ticks behind its own tick it was drawing others (view_ticks_behind). The server
## never trusts that blindly: it's limited to between 0 and NetworkSession.rewind_cap_seconds.
##
## Rules, checked in tests/net_selftest.gd:
##   - Past the cap, a high-ping shooter has to lead the target.
##   - An entity with no record of that tick stays where it is for the check.
##   - Everyone goes back to their real position before this returns, including in the collision world.
##   - Only for attacks. Movement is never rewound on the server.
##   - Only runs on the authority, inside a tick.
##   - Tier 0 rewinds once per attack, not once per tick for all attacks, which costs more if many fire on the same tick.
class_name LagCompensation
extends RefCounted


## A ray from origin along direction. Returns {} for no hit, otherwise {"position": Vector3, "collider": Object,
## "entity": NetworkEntity or null}. A wall in the way blocks it, because the world doesn't rewind.
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
	var found: Array[NetworkEntity] = []
	var body := shooter.get_parent() as Node3D
	if body == null:
		return found
	var rewound := _rewind_others(shooter, view_ticks_behind)
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, centre)
	if body is CollisionObject3D:
		query.exclude = [body.get_rid()]
	for hit: Dictionary in body.get_world_3d().direct_space_state.intersect_shape(query):
		var entity := _entity_of(hit["collider"])
		if entity and not found.has(entity):
			found.append(entity)
	_restore(rewound)
	return found


static func _rewind_others(shooter: NetworkEntity, view_ticks_behind: float) -> Array[NetworkEntity]:
	var rewound: Array[NetworkEntity] = []
	var session: Node = shooter.session
	if session == null or not session.lag_compensation_enabled:
		return rewound
	var driver: Node = shooter.get_node_or_null("/root/NetworkTime")
	if driver == null:
		return rewound
	var cap: float = session.rewind_cap_seconds * driver.get_tick_rate()
	var view_tick: float = driver.tick - clampf(view_ticks_behind, 0.0, cap)
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
