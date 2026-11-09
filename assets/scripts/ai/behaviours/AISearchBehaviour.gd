## Written by Claude (claude-opus-5-5), 2026-11-09: hunts around where an enemy it became certain of was last seen. Pawn spec section 10.7. Allowed
## in Alert by default.
##
## It scores high while the most aware entry in memory became certain but isn't fresh enough for Combat: "I know you were here". It
## runs (holding sprint, if sprint_to_last_known is on) to the last known position, then walks to search_points random points within
## search_radius of it, standing pause_ticks at each, and succeeds. If the pawn is still Alert, the next decision usually picks it
## again, so it keeps searching until the entry fades (Idle) or the enemy is seen again (Combat).
##
## It's only available when the most aware entry became certain: Look Toward and Investigate handle half-noticed things.
class_name AISearchBehaviour
extends AIBehaviourBase

## How many points it looks at around the last known position, each round.
@export_range(0, 50, 1, "or_greater") var search_points := 3
## How far from the last known position those points are, in metres.
@export_range(0.5, 100.0, 0.5, "or_greater") var search_radius := 5.0
## How long it stands at each, in ticks.
@export_range(1, 36000, 1, "or_greater") var pause_ticks := 30
## On: it holds sprint on the way to the last known position.
@export var sprint_to_last_known := true

const POINT_ANGLE_SALT := 0x5EA1
const POINT_DISTANCE_SALT := 0x5EA2

var _centre := Vector3.ZERO
var _going_to_centre := false
var _points_left := 0
var _pause_until := -1 # the tick its current pause ends; -1: not pausing


func _init() -> void:
	super()
	allowed_states = [&"Alert"]
	max_score = 0.7
	min_score = max_score # a fixed score, so it can help skip others
	tick_interval_ticks = 5 # Claude 2026-11-09: it only needs to notice when a walk or a pause ends


# Only for an enemy it became certain of: the most aware entry in memory exists and is certain. Its score is always max_score.
func is_available(context: AIContextComponent) -> bool:
	var index := context.most_aware_index()
	return index >= 0 and context.memory.is_certain_at(index)


func enter(context: AIContextComponent) -> void:
	var index := context.most_aware_index()
	_centre = context.memory.last_known_position_at(index) if index >= 0 else pawn.global_position
	_going_to_centre = true
	_points_left = search_points
	_pause_until = -1
	context.controller.hold(&"sprint", sprint_to_last_known)
	context.controller.move_to(_centre)


func tick(context: AIContextComponent) -> Status:
	var hands := context.controller
	# Claude 2026-11-09: pauses end at a tick, not after a count of tick() calls, so they last the same at any tick_interval_ticks.
	if _pause_until >= 0:
		if context.current_tick < _pause_until:
			return Status.RUNNING
		_pause_until = -1
		if _points_left <= 0:
			return Status.SUCCEEDED
		_points_left -= 1
		# GDScript note: sqrt spreads the points evenly over the circle rather than bunching them in the middle.
		var angle := context.random_unit(POINT_ANGLE_SALT) * TAU
		var distance := sqrt(context.random_unit(POINT_DISTANCE_SALT)) * search_radius
		hands.move_to(_centre + Vector3(cos(angle), 0.0, sin(angle)) * distance)
		return Status.RUNNING
	if hands.is_following_order():
		return Status.RUNNING
	# A walk ended: it arrived, or there was no way there. Stand and look around before the next one.
	if _going_to_centre:
		_going_to_centre = false
		hands.hold(&"sprint", false)
	_pause_until = context.current_tick + maxi(TickDriver.ticks_at_rate(pause_ticks), 1) # Claude 2026-11-09 (step 6)
	return Status.RUNNING


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.hold(&"sprint", false)
		context.controller.stop()
