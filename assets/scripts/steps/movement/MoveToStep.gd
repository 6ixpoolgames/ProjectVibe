# Written by Claude (claude-opus-5-5), 2026-11-25. History: steps/CHANGELOG.md.
## Walks the pawn to a point along a nav path: done on arriving, failed when there's no way there (pawn spec 16.7's MoveTo).
##
## Set [member goal] before it starts (a timeline entry's values, or code). With no nav at all it walks a straight line; while nav is
## still being built it waits, standing. The player's click-to-move runs one on its [ControllerStepHost]; AI behaviours walk with one.
## Right after starting it, [method MoveStep.gave_up] says whether there was no way there at all.
class_name MoveToStep
extends MoveStep

## Where it walks to.
@export var goal := Vector3.ZERO


func enter() -> void:
	super()
	walk_to(goal)


func current_goal() -> Vector3:
	return goal


func tick(_dt: float) -> Status:
	steer()
	match follower.get_path_state():
		PathFollower.PathState.ARRIVED:
			return Status.DONE
		PathFollower.PathState.UNREACHABLE:
			return Status.FAILED
	return Status.RUNNING
