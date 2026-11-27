# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Stops the [HoldStep]s running on its timeline that hold [member action] (every one with it empty) as it starts, and is done on its
## first tick (pawn spec 16.7's Release).
class_name ReleaseStep
extends InputStep

## The action to let go of. Empty: every held action.
@export var action: StringName = &""


func enter() -> void:
	if timeline == null:
		return
	for step in timeline.steps:
		if step is HoldStep and step.running and (action == &"" or (step as HoldStep).action == action):
			timeline.stop_step(step)


func tick(_dt: float) -> Status:
	return Status.DONE
