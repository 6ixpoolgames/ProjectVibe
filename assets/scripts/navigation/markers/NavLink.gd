# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## A connection nav can't walk across: an off-mesh link (nav spec section 21.3).
##
## A ladder, a jump, a door and a teleporter are all NavLinks, told apart by their tags (link.climb, link.jump, link.door,
## link.teleport), because they hold the same data. NavLinkModule hands them to nav, so pawns' paths can use them; without that module
## in the level they're registered and do nothing.
# GDScript note: "extends NavMarker" means a NavLink has everything a NavMarker has, plus what's below.
# class_name also adds it to the inspector's list of types, and "marker is NavLink" works anywhere.
class_name NavLink
extends NavMarker

## Where the link ends, relative to its start. An offset means it stays right if the whole thing is placed elsewhere.
@export var end_offset := Vector3.ZERO
## True = usable in both directions. False = start to end only, such as dropping off a ledge.
@export var two_way := true
## Added to a path's cost when it uses this link, so pawns prefer walking when the walk isn't much longer. Not used yet: links cost
## their length for now.
@export var extra_cost := 0.0
## The named action a pawn presses when it reaches the link, from InputActions, the same names a player's keys press. Jump by
## default. Empty means it just walks across, such as dropping off a ledge or going through an open door.
@export var press_action: StringName = &"jump"


## Where the link ends, in world space.
func get_end_position() -> Vector3:
	return position + end_offset


## Turning a placed link turns where it ends too.
func place_at(world_transform: Transform3D) -> void:
	# GDScript note: super.place_at runs the parent class's version, and this adds to it.
	super.place_at(world_transform)
	end_offset = world_transform.basis * end_offset
