## Written by Claude (claude-opus-5-5), 2026-11-09: the base for one AI state, such as Idle, Alert or Combat. A child of the pawn's
## AIStateManager. Pawn spec section 10.6.
##
## A state is "what situation am I in". It doesn't act: it decides which behaviours are allowed (each behaviour lists its states by
## node name) and, with its priority, how strong a reason its arrival is for interrupting the running behaviour.
##
## How the state is picked: the state manager checks each state's prerequisites_met() from the highest priority down, and the
## first that holds wins. No separate rules for staying, and no minimum time in a state.
##
## How to make one: extend this and override prerequisites_met(). Read thresholds from @export settings, never from numbers in
## code, so designers can tune them. Optionally override enter() and exit().
##
## The state's name is its node name, such as Idle. Behaviours' allowed_states and the debug readout use it.
class_name AIStateBase
extends Node

## Higher is checked first. A state change is also an interrupt event of this priority (pawn spec 10.7).
@export var priority := 0

## Set by the AIStateManager.
var manager: AIStateManager = null


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
