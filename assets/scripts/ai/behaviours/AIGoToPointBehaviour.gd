# Written by Claude (claude-opus-5-5), 2026-11-15. History: ai/CHANGELOG.md.
## Walks to a meeting point: the nearest node in a Godot group, "rally_point" by default.
##
## The owner's request: in the mass battle, every faction marches to the middle and fights there, instead of wandering near its
## spawner. Like Unreal's target points: the point is a node in a Godot group ([member point_group]), placed in the level, so pawns
## spawned at any time find it.
## [br]
## When it's available: there's a node in point_group, and the pawn is further than [member arrive_radius] from it (one condition on
## the input group_distance/<point_group>; the nearest node is looked for again every 2 seconds, [method AIInputs.nearest_in_group]). Allowed in Idle,
## the same as Wander, with a score just above Wander's (0.15 against 0.1), so an idle pawn marches, anything it notices on the way
## (Alert, Combat) takes over, and once it's there, Wander takes over and it mills about.
## [br]
## How it walks: in legs of at most [member leg_metres] toward the point, each one a move_to, so each path stays short. Nav is only
## built near streaming sources (StreamingSource.nav_distance), so one path all the way across a big level might not exist yet, while
## a short leg does. Each pawn walks a little to one side of the straight line (up to [member spread_metres], its own offset from its
## random numbers), so a crowd marches as a band, not in single file. A leg that can't be walked is tried again a few metres shorter
## on its next tick.
## [br]
## It never finishes on its own: it returns RUNNING, and stops being available once the pawn has arrived.
class_name AIGoToPointBehaviour
extends AIBehaviourBase

## The Godot group the point is in. The nearest node in it is the point.
@export var point_group: StringName = &"rally_point"
## Close enough, in metres. Inside this the behaviour isn't available, so Wander takes over.
@export_range(0.5, 500.0, 0.5, "or_greater") var arrive_radius := 15.0
## The longest leg it walks at once, in metres.
@export_range(2.0, 200.0, 0.5, "or_greater") var leg_metres := 30.0
## How far to one side of the straight line this pawn walks, at most, in metres.
@export_range(0.0, 100.0, 0.5, "or_greater") var spread_metres := 6.0

const SIDE_SALT := 0x60A1

var _shorten := 0.0 # metres taken off the next leg after one that couldn't be walked


func _init() -> void:
	super()
	allowed_states = [&"Idle"]
	max_score = 0.15
	min_score = 0.15
	tick_interval_ticks = 60 # the safety net: it wakes when a leg ends (wake_on_path_end)


## There's a node in point_group, and the pawn is further than arrive_radius from the nearest one: two conditions.
func own_conditions() -> Array[AICondition]:
	var list: Array[AICondition] = [
		AICompareCondition.make(StringName(AIInputs.GROUP_FOUND + String(point_group)), AICompareCondition.Comparison.EQUAL, 1.0),
		AICompareCondition.make(StringName(AIInputs.GROUP_DISTANCE + String(point_group)), AICompareCondition.Comparison.MORE_THAN,
			arrive_radius),
	]
	return list


func enter(_context: AIContextComponent) -> void:
	_shorten = 0.0
	wake_on_path_end()


func tick(context: AIContextComponent) -> Status:
	var hands := context.controller
	var point := context.inputs.nearest_in_group(point_group, context.current_tick) if pawn else null
	if hands == null or point == null:
		return Status.FAILED
	if hands.is_following_order():
		return Status.RUNNING
	var to := point.global_position - pawn.global_position
	to.y = 0.0
	var distance := to.length()
	if distance <= arrive_radius:
		return Status.RUNNING # arrived; the next decision picks something else
	var ahead := to / distance
	# Its own side of the line, the same every leg: from its number, not the tick, so it doesn't zig-zag.
	var side := (context.random_unit_at(0, SIDE_SALT) * 2.0 - 1.0) * spread_metres
	var across := Vector3(-ahead.z, 0.0, ahead.x)
	var leg := maxf(minf(leg_metres - _shorten, distance), 2.0)
	var target := pawn.global_position + ahead * leg + across * side * minf(1.0, distance / leg_metres)
	if hands.move_to(target):
		_shorten = 0.0
	else:
		_shorten = minf(_shorten + 5.0, leg_metres - 2.0) # shorter next time, toward ground nav has built
		wake_at(context.current_tick + TickDriver.ticks_at_rate(5)) # and soon: no walk is under way to wake it
	return Status.RUNNING


func exit(context: AIContextComponent, _reason: String) -> void:
	if context and context.controller:
		context.controller.stop()

