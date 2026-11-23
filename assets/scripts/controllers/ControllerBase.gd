# Written by Claude (claude-opus-5-5), 2026-11-07. History: controllers/CHANGELOG.md.
## The base class every controller shares: PlayerController and AIController extend it.
##
## Pawn spec section 6. A controller decides nothing about how a pawn moves. Its only output is one InputCommand per tick, and the
## pawn's abilities do the rest. That's why a player and the AI can take turns driving the same pawn.
## [br]
## How to make one: extend this, and override [method take_input_command].
class_name ControllerBase
extends Node

## Sent when this controller gets a pawn or loses it. The pawn is null if it has none now.
# Sent by the controllers that extend this (PlayerController), so the editor's "never used" warning is off here.
@warning_ignore("unused_signal")
signal pawn_changed(pawn: Pawn)

## The pawn this controller drives, or null.
var pawn: Pawn = null


## This tick's input. Called once per tick. The default is an idle command: standing still, nothing held.
func take_input_command(_tick: int) -> InputCommand:
	# "take", not "get", because a controller may use things up here, such as the presses saved since the last tick; calling it
	# twice in one tick would lose them.
	return InputCommand.new()
