# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Holds an action for one tick, so the pawn sees one press, and is done (pawn spec 16.7's Press).
class_name PressStep
extends InputStep

## The action it presses, such as &"dash".
@export var action: StringName = &""


func tick(_dt: float) -> Status:
	if input and action != &"":
		input.write_held(InputActions.mask_of(action))
	return Status.DONE
