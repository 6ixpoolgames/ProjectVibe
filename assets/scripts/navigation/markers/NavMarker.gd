# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## The base data object for nav markers: "this spot means something to nav or AI" (nav spec 21.2).
##
## Plain data with no behaviour: modules ([NavMarkerModule]) hold the code that acts on markers, so a marker nothing handles is
## ignored. Registering copies its position, tag and enabled state into NavMarkerManager's rows, so changing them here afterwards
## does nothing; switch one during play with [code]NavMarkerManager.set_enabled(id, value)[/code].
class_name NavMarker
extends Resource

## What this marker is, such as &"link.jump". Must be declared for NavTags, or NavMarkerManager refuses the marker.
@export var tag: StringName
## How close counts as "at it".
@export var radius := 1.0
## False = registered, but not used until someone switches it on.
@export var starts_enabled := true

# Not exported: the generator or the placing node sets these just before registering.
var position := Vector3.ZERO
## Which way it faces, for cover direction, seats and so on.
var facing := Vector3.FORWARD


## Sets where the marker is from a node's world transform. A subclass with more placed data adds to this.
func place_at(world_transform: Transform3D) -> void:
	position = world_transform.origin
	# Godot's forward is minus Z, so that's the way a node "faces".
	facing = -world_transform.basis.z.normalized()
