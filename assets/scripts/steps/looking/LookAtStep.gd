# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Looks at a point, or keeps looking at a target, aimed from the pawn's eyes (pawn spec 16.7's LookAt).
##
## With [member target] set it looks at the target's position plus [member offset], worked out again every tick; once the target is
## gone it keeps its last aim. Otherwise it looks at [member point]. It runs until stopped, or for its length. AI sight faces where it
## looks ([SightSense]).
class_name LookAtStep
extends InputStep

## The point it looks at when it has no [member target].
@export var point := Vector3.ZERO
## What it keeps looking at. Empty: [member point].
@export var target: Node3D = null
## Added to the target's position: 1 m up looks at a body, not its feet.
@export var offset := Vector3(0.0, 1.0, 0.0)

var _last_aim := Vector3.ZERO


func enter() -> void:
	_last_aim = point


func tick(_dt: float) -> Status:
	if target != null:
		if is_instance_valid(target):
			_last_aim = target.global_position + offset
		else:
			target = null # gone: keep the last aim
	if input and pawn:
		input.look_at(eye_position(), _last_aim)
	return Status.RUNNING
