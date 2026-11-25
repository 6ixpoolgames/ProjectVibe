# Written by Claude (claude-opus-5-5), 2026-11-25. History: steps/CHANGELOG.md.
## The base of steps that walk the pawn along a nav path: holds a [PathFollower] and writes its direction into the host's input.
##
## [MoveToStep] extends it; Follow and KeepAwayFrom will (pawn spec 16.7). Its host is whatever owns its timeline and has an
## [code]input[/code] (an [InputCommand]) its steps write: a [ControllerStepHost] today, an AI behaviour from step 7. Each tick it
## writes the follower's direction into the input's move and ORs in a link's action ([method steer]). The settings below are
## copied into the follower when the timeline is built; in code, change [member follower] itself.
## [br][br]Rollback: the follower doesn't roll back yet. The player's host runs on the owner's machine only, whose input is what
## rolls back.
class_name MoveStep
extends Step

## How close, in metres, the pawn must get to a corner of the path before it heads for the next one (measured flat).
@export var corner_reached_distance := 0.5
## How close, in metres, it must get to the end of the path to count as arrived.
@export var arrival_distance := 0.3
## Which size of nav to use. 0 is the smallest; t0 builds only tier 0.
@export var nav_tier := 0
## On, paths may cross links (jumps, drops, placed links). Off for a pawn that can't jump.
@export var use_links := true
## How long the pawn has to cross a link, in ticks at 60 a second, before it finds a new path to the same place.
@export_range(0, 600, 1, "or_greater") var link_timeout_ticks := 180
## On, with no nav at all (and none being built) it walks in a straight line. Off, that's no way there.
@export var straight_line_without_nav := true
## While waiting for nav to be built, how often it tries again, in ticks at 60 a second.
@export_range(1, 600, 1, "or_greater") var pending_retry_ticks := 10
## How long it waits for nav to be built or a queued path to come, in ticks at 60 a second, before giving up.
@export_range(1, 3600, 1, "or_greater") var pending_give_up_ticks := 300

## The path it follows. Its settings come from the ones above when the timeline is built.
var follower := PathFollower.new()


func setup() -> void:
	follower.corner_reached_distance = corner_reached_distance
	follower.arrival_distance = arrival_distance
	follower.nav_tier = nav_tier
	follower.use_links = use_links
	follower.link_timeout_ticks = link_timeout_ticks
	follower.straight_line_without_nav = straight_line_without_nav
	follower.pending_retry_ticks = pending_retry_ticks
	follower.pending_give_up_ticks = pending_give_up_ticks


func enter() -> void:
	follower.pawn = pawn


func exit(_reason: String) -> void:
	follower.stop()


## Writes this tick's direction into the host's input, and presses a link's action the path just reached. Call it once per tick,
## from [method Step.tick]: it moves the follower on.
func steer() -> void:
	var input := host_input()
	var direction := follower.get_move_direction()
	var press := follower.take_link_press()
	if input:
		input.move = direction
		input.held_actions |= press


## The input its host's steps write, or null when its host has none.
func host_input() -> InputCommand:
	var host: Object = timeline.host if timeline else null
	return host.get(&"input") as InputCommand if host else null
