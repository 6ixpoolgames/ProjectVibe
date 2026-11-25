# Written by Claude (claude-opus-5-5), 2026-11-25. History: steps/CHANGELOG.md.
## The base of steps that walk the pawn along a nav path: holds a [PathFollower] and writes its direction into the host's input.
##
## [MoveToStep] extends it; Follow and KeepAwayFrom will (pawn spec 16.7). Its host is whatever owns its timeline and has an
## [code]step_input()[/code] method giving the [InputCommand] its steps write: a [ControllerStepHost] today, an AI behaviour from
## step 7. Each tick it writes the follower's direction into that input's move and ORs in a link's action ([method steer]). Why a
## walk failed is [code]follower.get_end_reason()[/code].
## [br][br]Rollback: the follower doesn't roll back yet. The player's host runs on the owner's machine only, whose input is what
## rolls back.
class_name MoveStep
extends Step

## How it follows its path (closeness, nav tier, links, waiting for nav). Empty: the defaults. Shared, so steps can use one.
@export var settings: PathFollowSettings

## The path it follows, with [member settings].
var follower := PathFollower.new()
## The input it writes: its host's ([code]step_input()[/code]), found when the timeline is built. Null: its host gives none, and it
## moves nothing (warned once).
var input: InputCommand = null


func setup() -> void:
	follower.settings = settings
	var host: Object = timeline.host if timeline else null
	input = host.call(&"step_input") as InputCommand if host and host.has_method(&"step_input") else null
	if input == null:
		push_warning("%s: its timeline's host gives no input (step_input()), so it moves nothing." % name)


func enter() -> void:
	follower.pawn = pawn


func exit(_reason: String) -> void:
	follower.stop()


## Writes this tick's direction into [member input], and presses a link's action the path just reached. Call it once per tick, from
## [method Step.tick]: it moves the follower on.
func steer() -> void:
	var direction := follower.get_move_direction()
	var press := follower.take_link_press()
	if input:
		input.move = direction
		input.held_actions |= press
