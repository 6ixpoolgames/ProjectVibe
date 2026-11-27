# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Holds an action while it runs: until stopped ([ReleaseStep]), or for its length (pawn spec 16.7's Hold).
##
## With [member fresh_press] on, an action the pawn's last input already held is let go for its first tick, so holding it starts with
## a press: an attack held through one swing would otherwise start the next with no press at all.
class_name HoldStep
extends InputStep

## The action it holds, such as &"sprint" or an attack's.
@export var action: StringName = &""
## On: if the last input held the action, it's let go for one tick first, so the hold begins with a press.
@export var fresh_press := false

var _hold_from := -1 # the tick it starts holding on


func enter() -> void:
	_hold_from = TickDriver.tick
	if fresh_press and pawn and pawn.controller_manager and pawn.controller_manager.held_actions & InputActions.mask_of(action) != 0:
		_hold_from += 1


## The tick its hold begins: a tick after it started when it had to let go first.
func hold_from_tick() -> int:
	return _hold_from


func tick(_dt: float) -> Status:
	if input and action != &"" and TickDriver.tick >= _hold_from:
		input.write_held(InputActions.mask_of(action))
	return Status.RUNNING
