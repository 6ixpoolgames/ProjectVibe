# Written by Claude (claude-opus-5-5), 2026-11-24. History: entities/CHANGELOG.md.
## One number for every entity, the same on every machine and in every replay (pawn spec 16.9).
##
## An entity's number is its network entity id when it has one, or else a hash of its path in the scene tree (a level's own pawns,
## offline). Everything that needs to name an entity across machines uses it: AI rolls and stagger, hit lists and hit order, effect
## sources, ties. Instance ids differ between machines and runs, so they're only for bookkeeping that stays on one machine. A pawn keeps
## its own ([method Pawn.entity_number]); this class works it out for anything else. A static class: nothing to add to a scene.
class_name EntityNumber
extends RefCounted

## No entity (null, or freed).
const NONE := -1


## The entity number of [param entity] (a pawn or any node), or [constant NONE]. Untyped, so a freed object can be passed.
static func of(entity) -> int:
	if entity == null or not is_instance_valid(entity) or not (entity is Node):
		return NONE
	if entity is Pawn:
		return (entity as Pawn).entity_number()
	if entity.has_method(&"get_network_entity"):
		var network_entity = entity.get_network_entity()
		if network_entity and network_entity.entity_id >= 0:
			return network_entity.entity_id
	return from_path(entity)


## A hash of the node's path in the scene tree (its name if it isn't in one), from 0 to 2^31 - 1. The same scene gives the same
## paths on every machine; two nodes never share a path, as they can share a name.
static func from_path(node: Node) -> int:
	var text := String(node.get_path()) if node.is_inside_tree() else String(node.name)
	return text.hash() & 0x7FFFFFFF
