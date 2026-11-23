# Written by Claude (claude-opus-5-5), 2026-11-07. History: controllers/CHANGELOG.md.
## One tick's input for a pawn, as plain values: what players and AI both make, and what goes over the network.
##
## Pawn spec section 5. Nothing holds what a pawn wants between ticks except the last input: there's no "intent".
## [br]
## How to use it: a controller makes one each tick, and the pawn's ControllerManager copies it into the pawn's input
## ([method ControllerManager.apply_input]). In a script or test, this is the short way:
## [codeblock]
## InputCommand.make(direction, [&"sprint"])
## [/codeblock]
class_name InputCommand
extends RefCounted

## Which way to go, in world space, up to length 1. Shorter means slower, as a stick pushed halfway gives.
var move := Vector3.ZERO
## Where the controller is looking, sideways, in radians. Often not where the pawn faces.
var look_yaw := 0.0
## Where the controller is looking, up and down, in radians.
var look_pitch := 0.0
## Which named actions are held this tick, as bits from InputActions. A press is "held this tick, not held last tick", which the
## ControllerManager works out, so a press is never sent twice.
var held_actions := 0
## How many ticks behind its own tick the sender was drawing other pawns, for lag compensation. The player's controller fills it
## from NetworkSession; the AI's stays 0.
var view_ticks_behind := 0.0


## A command in one line. held is a list of action names, such as [code][&"jump", &"sprint"][/code].
static func make(move_direction := Vector3.ZERO, held: Array = [], yaw := 0.0, pitch := 0.0) -> InputCommand:
	var command := InputCommand.new()
	command.move = move_direction
	command.held_actions = InputActions.mask_of_list(held)
	command.look_yaw = yaw
	command.look_pitch = pitch
	return command


func is_held(action: StringName) -> bool:
	return held_actions & InputActions.mask_of(action) != 0


func set_held(action: StringName, held := true) -> void:
	if held:
		held_actions |= InputActions.mask_of(action)
	else:
		held_actions &= ~InputActions.mask_of(action)
