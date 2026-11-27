# Written by Claude (claude-opus-5-5), 2026-11-25. History: steps/CHANGELOG.md.
## The base of steps that walk the pawn along a nav path: holds a [PathFollower] and writes its direction into the host's input.
##
## [MoveToStep], [FollowStep] and [KeepAwayFromStep] extend it (pawn spec 16.7). Each tick [method steer] writes the follower's
## direction into the host's [StepInput] and ORs in a link's action. It finds a new path to [method current_goal]:
## [br]- when the walk was dropped (charge changed hands) or a rollback loaded old state: a path isn't state, so after a rollback, or
## on a client, it's found afresh;
## [br]- every [member repath_ticks], if set;
## [br]- once the pawn is more than [member off_path_metres] from its path (knocked off it), if set;
## [br]- after a link isn't crossed in time (the follower itself, [member PathFollowSettings.link_timeout_ticks]).
## [br]Why a walk failed is [code]follower.get_end_reason()[/code].
class_name MoveStep
extends InputStep

## How it follows its path (closeness, nav tier, links, waiting for nav). Shared, so steps can use one. Empty: the AI controller's
## [member AIController.path_settings] on an AI pawn, else the defaults.
@export var settings: PathFollowSettings
## Finds a new path this often, in ticks at 60 a second. 0: only when the rules above call for one.
@export_range(0, 600, 1, "or_greater") var repath_ticks := 0
## Finds a new path once the pawn is this far, flat, from the path (knocked off it). 0: never for that.
@export_range(0.0, 50.0, 0.1, "or_greater") var off_path_metres := 0.0

## The path it follows, with [member settings].
var follower := PathFollower.new()

var _path_tick := -1 # the tick its current path was asked for
var _rollbacks_seen := 0 # TickDriver.rollbacks_loaded when its path was asked for
var _walking := false # a path was asked for and should be under way


func enter() -> void:
	follower.pawn = pawn
	var hands := pawn.ai.controller if pawn and pawn.ai and not settings else null
	follower.settings = settings if settings else (hands.path_settings if hands else null)
	_walking = false


func exit(_reason: String) -> void:
	# Only a walk still under way is stopped, so an arrival or a give-up keeps its state and end reason for whoever asks after.
	if follower.is_under_way():
		follower.stop()
	_walking = false


## Where it's walking to now. MoveTo's goal; Follow's, worked out from its target.
func current_goal() -> Vector3:
	return follower.get_goal()


## Finds a path to this point now. False if there's no way there (the follower is UNREACHABLE).
func walk_to(point: Vector3) -> bool:
	_path_tick = TickDriver.tick
	_rollbacks_seen = TickDriver.rollbacks_loaded
	_walking = true
	return follower.move_to(point)


## True once its path ended without arriving and no new one is coming: no way there, nav too slow, a link missed twice.
func gave_up() -> bool:
	return follower.get_path_state() == PathFollower.PathState.UNREACHABLE


## Writes this tick's direction into the input, and presses a link's action the path just reached. Finds a new path first if a rule
## above calls for one. Call it once per tick, from [method Step.tick]: it moves the follower on.
func steer() -> void:
	if _walking and _needs_new_path():
		walk_to(current_goal())
	var direction := follower.get_move_direction() if follower.is_under_way() else Vector3.ZERO
	var press := follower.take_link_press()
	if input:
		input.write_move(direction)
		input.write_held(press)


## True once [member repath_ticks] have passed since its path was asked for (never with 0).
func repath_due() -> bool:
	return repath_ticks > 0 and TickDriver.tick - _path_tick >= TickDriver.ticks_at_rate(repath_ticks)


func _needs_new_path() -> bool:
	var state := follower.get_path_state()
	if state == PathFollower.PathState.NONE:
		return true # dropped while it should be walking
	if TickDriver.rollbacks_loaded != _rollbacks_seen:
		return true
	if state != PathFollower.PathState.FOLLOWING:
		return false # waiting, arrived or given up: nothing to find again
	if repath_due():
		return true
	return off_path_metres > 0.0 and follower.distance_off_path() > off_path_metres
