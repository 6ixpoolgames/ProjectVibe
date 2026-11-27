# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Stops every look step running on its timeline (LookAt, LookInDirection) as it starts, and is done on its first tick (pawn spec
## 16.7's StopLooking). With no look step running, the pawn keeps the look it has.
class_name StopLookingStep
extends InputStep


func enter() -> void:
	stop_running_steps_of(LookAtStep)
	stop_running_steps_of(LookInDirectionStep)


func tick(_dt: float) -> Status:
	return Status.DONE
