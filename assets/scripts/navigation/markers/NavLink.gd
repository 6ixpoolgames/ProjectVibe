## Written by Claude (claude-opus-5-5), 2026-11-06: a connection nav can't walk across (nav spec section 21.3).
## The usual term is an off-mesh link. A ladder, a jump, a door and a teleporter are all NavLinks, told apart
## by their tags (link.climb, link.jump, link.door, link.teleport), because they hold the same data.
## NavLinkModule will hand these to nav. Until that exists they're registered and do nothing.
##
# GDScript note: "extends NavMarker" means a NavLink has everything a NavMarker has, plus what's below.
# class_name also adds it to the inspector's list of types, and "marker is NavLink" works anywhere.
class_name NavLink
extends NavMarker

## Where the link ends, relative to its start. An offset means it stays right if the whole thing is placed elsewhere.
@export var end_offset := Vector3.ZERO
## True = usable in both directions. False = start to end only, such as dropping off a ledge.
@export var two_way := true
## Added to a path's cost when it uses this link, so pawns prefer walking when the walk isn't much longer.
@export var extra_cost := 0.0
## The ability tag to play when a pawn reaches the link, such as &"movement.jump". This one goes through
## TagRegistry, not NavTags, because abilities have their own tags.
@export var action_tag: StringName


## Where the link ends, in world space.
func get_end_position() -> Vector3:
	return position + end_offset


## Turning a placed link turns where it ends too.
func place_at(world_transform: Transform3D) -> void:
	# GDScript note: super.place_at runs the parent class's version, and this adds to it.
	super.place_at(world_transform)
	end_offset = world_transform.basis * end_offset
