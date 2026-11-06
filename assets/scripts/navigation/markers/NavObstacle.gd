## Written by Claude (claude-opus-5-5), 2026-11-06: something that doesn't navigate but affects paths (nav spec sections 11 and 21.3).
## The usual term is a dynamic obstacle, such as a crate, a parked vehicle or a fallen tree.
## NavObstacleModule will hand these to nav's ObstacleSystem. Until that exists they're registered and do nothing.
class_name NavObstacle
extends NavMarker

# GDScript note: an enum inside a class is reached from outside as NavObstacle.Mode.CARVE.
enum Mode {
	AVOID, ## Agents steer around it, and paths ignore it. Almost free, so it suits moving things.
	CARVE, ## Cut out of the nav map, so paths go around it. Rebuilds tiles, so it suits things that stay put.
	COST,  ## Paths can cross it but prefer not to, using cost_surface.
}

## How it affects nav. The spec also has an automatic setting that switches as things start and stop moving,
## which comes with the module.
@export var mode := Mode.AVOID
## The box it covers, in metres, centered on the marker's position.
@export var size := Vector3(1.0, 2.0, 1.0)
## The nav surface it counts as in COST mode.
@export var cost_surface: StringName
