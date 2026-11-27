# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## The base of steps that write a pawn's input: moving, looking and buttons (pawn spec 16.7).
##
## Its host is whatever owns its timeline and has a [code]step_input()[/code] method giving the [StepInput] its steps write: an AI
## behaviour, or a [ControllerStepHost]. The host clears that input before its steps run each tick; a step writes its part in
## [method Step.tick]. Steps that stop others (StopMoving, Release) look through [member Step.timeline] for them.
class_name InputStep
extends Step

## The input it writes: its host's ([code]step_input()[/code]), found when the timeline is built. Null: its host gives none, and it
## writes nothing (warned once).
var input: StepInput = null


func setup() -> void:
	var host: Object = timeline.host if timeline else null
	input = host.call(&"step_input") as StepInput if host and host.has_method(&"step_input") else null
	if input == null:
		push_warning("%s: its timeline's host gives no input (step_input()), so it writes nothing." % name)


## Where the pawn's eyes are, for looks: [member Pawn.eye_height] above its feet.
func eye_position() -> Vector3:
	return pawn.global_position + Vector3(0.0, pawn.eye_height, 0.0) if pawn else Vector3.ZERO


## Stops every running step on its timeline that is one of this script class (StopMoving stops MoveSteps), except itself.
func stop_running_steps_of(kind: Script, reason := "cancelled") -> void:
	if timeline == null:
		return
	for step in timeline.steps:
		if step != self and step.running and _is_kind(step, kind):
			timeline.stop_step(step, reason)


static func _is_kind(step: Step, kind: Script) -> bool:
	var script: Script = step.get_script()
	while script:
		if script == kind:
			return true
		script = script.get_base_script()
	return false
