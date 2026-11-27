# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Closes in on a target along nav paths and stands [member stop_distance] from it (flat), walking again once it's further than that
## plus [member band] (pawn spec 16.7's Follow).
##
## Set [member target] before it starts. It runs until stopped; once the target is gone (freed) it stands and is done. It finds a new
## path when the target has moved [member repath_distance] from where its path leads, every [member MoveStep.repath_ticks] (20 by
## default), and by [MoveStep]'s other rules. It reads only the target's real position, so every machine does the same. Looking at
## the target is a separate step ([LookAtStep]).
class_name FollowStep
extends MoveStep

## What it closes in on.
@export var target: Node3D = null
## How near, in metres, flat, it stands.
@export_range(0.0, 50.0, 0.1, "or_greater") var stop_distance := 1.2
## How much further it may drift before walking again, so it doesn't twitch at the edge. It stands once within half of it.
@export_range(0.0, 20.0, 0.05, "or_greater") var band := 0.3
## Finds a new path once the target has moved this far from where the path leads, in metres.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 1.5

var _standing := false
var _goal := Vector3.ZERO


func _init() -> void:
	super()
	repath_ticks = 20


func enter() -> void:
	super()
	_standing = false
	_goal = Vector3.INF


func current_goal() -> Vector3:
	return _goal


## True while it stands, near enough (or, keeping away, at its distance).
func is_standing() -> bool:
	return _standing


## Where it walks to for a target at [param there], [param distance] away from the pawn now (flat).
func goal_for(there: Vector3, _away: Vector3, _distance: float) -> Vector3:
	return there


## How far off its distance the pawn is: only too far matters when closing in.
func off_by(distance: float) -> float:
	return distance - stop_distance


func tick(_dt: float) -> Status:
	if not is_instance_valid(target) or pawn == null:
		follower.stop()
		return Status.DONE # the target is gone: stand
	var there := target.global_position
	var away := pawn.global_position - there
	away.y = 0.0
	var distance := away.length()
	# Stands once inside half the band (from walking), walks again once outside the whole band.
	if off_by(distance) <= (band if _standing else band * 0.5):
		if not _standing:
			_standing = true
			follower.stop()
			_walking = false # standing: MoveStep's rules mustn't find a path again
		return Status.RUNNING
	var goal := goal_for(there, away, distance)
	if _standing or goal.distance_to(_goal) > repath_distance or not follower.is_under_way() or repath_due():
		_standing = false
		_goal = goal
		walk_to(goal)
	steer()
	return Status.RUNNING
