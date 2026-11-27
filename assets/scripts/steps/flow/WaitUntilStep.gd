# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Waits until its [member condition] holds, then is done; with a length, it gives up (fails) once that runs out (pawn spec 16.7's
## WaitUntil). With no condition it's done at once.
class_name WaitUntilStep
extends Step

## What it waits for, asked every tick it runs.
@export var condition: StepCondition = null
## On: running out of length counts as failing, which ends the owner's run. Off: as done.
@export var fails_on_timeout := true


func tick(_dt: float) -> Status:
	if condition == null or condition.holds(timeline):
		return Status.DONE
	var total := length()
	if total > 0 and step_ticks + 1 >= total:
		return Status.FAILED if fails_on_timeout else Status.DONE
	return Status.RUNNING
