# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Stops every move step running on its timeline (MoveTo, Follow, KeepAwayFrom) as it starts, and is done on its first tick
## (pawn spec 16.7's StopMoving). With no move step running, the pawn stands: nothing writes a move.
class_name StopMovingStep
extends InputStep


func enter() -> void:
	stop_running_steps_of(MoveStep)


func tick(_dt: float) -> Status:
	return Status.DONE
