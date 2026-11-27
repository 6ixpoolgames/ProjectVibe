# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Looks one way, as a yaw and pitch in degrees, until stopped or for its length (pawn spec 16.7's LookInDirection).
##
## Yaw 0 looks along -Z, Godot's forward; positive turns left. Pitch is up from level.
class_name LookInDirectionStep
extends InputStep

## Which way round, in degrees.
@export_range(-180.0, 180.0, 0.5) var yaw_degrees := 0.0
## How far up (below 0: down), in degrees.
@export_range(-90.0, 90.0, 0.5) var pitch_degrees := 0.0


func tick(_dt: float) -> Status:
	if input:
		input.write_look(deg_to_rad(yaw_degrees), deg_to_rad(pitch_degrees))
	return Status.RUNNING
