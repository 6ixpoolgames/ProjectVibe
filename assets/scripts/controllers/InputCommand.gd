## Written by Claude (claude-opus-5-5), 2026-11-07: one tick's input for a pawn, as plain values. Players and AI make the same shape, and
## it's what goes over the network. Pawn spec section 5. This replaces the old idea of "intent": nothing holds what a pawn wants
## between ticks except the last input.
##
## How to use it: a controller makes one each tick and gives it to Pawn.apply_input(). In a script or test,
## InputCommand.make(direction, [&"sprint"]) is the short way.
class_name InputCommand
extends RefCounted

## Which way to go, in world space, up to length 1. Shorter means slower, as a stick pushed halfway gives.
var move := Vector3.ZERO
## Where the controller is looking, in radians. Often not where the pawn faces.
var look_yaw := 0.0
var look_pitch := 0.0
## Which named actions are held this tick, as bits from InputActions. A press is "held this tick, not held last tick", which the
## pawn works out, so a press is never sent twice.
var held_actions := 0
## Claude 2026-11-09: how many ticks behind its own tick the sender was drawing other pawns, for lag compensation (step 9). The
## player's controller fills it from NetworkSession; the AI's stays 0.
var view_ticks_behind := 0.0


## A command in one line. held is a list of action names, such as [&"jump", &"sprint"].
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
