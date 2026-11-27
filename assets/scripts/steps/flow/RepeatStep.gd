# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Runs another step of its timeline again each time it ends, [member times] times in all (0: until stopped), then is done (pawn spec
## 16.7's Repeat). Stopping it stops the step it repeats.
class_name RepeatStep
extends Step

## The step it repeats, by node name.
@export var step: StringName = &""
## How many runs in all. 0: until stopped.
@export_range(0, 1000, 1, "or_greater") var times := 0

var _runs := 0
var _repeated: Step = null


func setup() -> void:
	_repeated = null
	if timeline:
		for candidate in timeline.steps:
			if candidate.name == step and candidate != self:
				_repeated = candidate
	if _repeated == null:
		push_warning("%s: its timeline has no step called '%s' to repeat." % [name, step])


func enter() -> void:
	_runs = 0
	_start_again()


func tick(_dt: float) -> Status:
	if _repeated == null:
		return Status.DONE
	if not _repeated.running:
		if times > 0 and _runs >= times:
			return Status.DONE
		_start_again()
	return Status.RUNNING


func exit(_reason: String) -> void:
	if _repeated and _repeated.running:
		timeline.stop_step(_repeated)


func _start_again() -> void:
	if _repeated and not _repeated.running:
		timeline.start_step(_repeated)
		_runs += 1
