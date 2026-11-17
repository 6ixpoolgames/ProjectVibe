# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## The base for one AI state, such as Idle, Alert or Combat: "what situation am I in".
##
## A child of the pawn's [AIStateManager]. A state doesn't act: it decides which behaviours are allowed (they list states by node name)
## and, with its [member priority], how strong a reason its arrival is for interrupting the running behaviour. The manager checks each
## state's [method prerequisites_met] from the highest priority down and the first that holds wins; there is no minimum time in a state.
## Extend it and override [method prerequisites_met], reading thresholds from exports so designers can tune them; optionally
## [method enter] and [method exit]. Its node name is its name.
## Design: pawn spec 10.6.
class_name AIStateBase
extends Node

## Higher is checked first. A state change is also an interrupt event of this priority (pawn spec 10.7).
@export var priority := 0

## Set by the AIStateManager.
var manager: AIStateManager = null
## The timing scope name for its prerequisites_met(), such as &"ai.state.Combat" (see [PerfScopes]). Made once by the manager.
var perf_name: StringName = &""


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## Whether this state fits right now. The base never fits, so a state that forgets to override this is never picked by mistake.
func prerequisites_met(_context: AIContextComponent) -> bool:
	return false


## Once, when the pawn enters this state.
func enter(_context: AIContextComponent) -> void:
	pass


## Once, when the pawn leaves this state.
func exit(_context: AIContextComponent) -> void:
	pass
