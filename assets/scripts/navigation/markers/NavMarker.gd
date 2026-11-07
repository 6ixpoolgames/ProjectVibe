## Written by Claude (claude-opus-5-5), 2026-11-06: the base data object for nav markers (nav spec section 21.2).
## A marker says "this spot means something to nav or AI", such as a ladder, a cover spot or a seat.
## It's plain data with no behaviour. Modules hold the code that acts on markers, so a marker nothing
## handles is simply ignored.
##
## A marker is INPUT. When it's registered, NavMarkerManager copies its position, tag and enabled state into its own
## rows, so changing those here afterwards does nothing. To switch a marker on or off during play, call
## NavMarkerManager.set_enabled(id, value).
##
# GDScript note: a Resource is a data object Godot can edit in the inspector and save to a file.
# It's much lighter than a node, because it isn't in the scene tree and gets no per-frame calls.
class_name NavMarker
extends Resource

## What this marker is, such as &"link.jump". Must be declared for NavTags, or NavMarkerManager refuses the marker.
@export var tag: StringName
## How close counts as "at it".
@export var radius := 1.0
## False = registered, but not used until someone switches it on.
@export var starts_enabled := true

# GDScript note: no @export on these two, so they don't appear in the inspector.
# The generator or the placing node sets them just before registering.
var position := Vector3.ZERO
## Which way it faces, for cover direction, seats and so on.
var facing := Vector3.FORWARD


## Sets where the marker is from a node's world transform. A subclass with more placed data adds to this.
func place_at(world_transform: Transform3D) -> void:
	position = world_transform.origin
	# Godot's forward is minus Z, so that's the way a node "faces".
	# GDScript note: a Transform3D holds a basis (rotation and scale) plus an origin (position).
	facing = -world_transform.basis.z.normalized()
