# Written by Claude (claude-opus-5-5), 2026-11-15. History: ai/CHANGELOG.md.
## Walks to a meeting point: the nearest node in a Godot group, "rally_point" by default.
##
## Allowed in Idle, scoring just above Wander (0.15 against 0.1), so an idle pawn marches to the point, anything it notices on the
## way takes over, and on arrival Wander takes over. Available while a node is in [member point_group] and the pawn is further than
## [member arrive_radius] from it (the nearest is looked up every 2 seconds, [method AIInputs.nearest_in_group]). It walks in legs of
## at most [member leg_metres], each a move_to, because nav is only built near streaming sources; a leg that can't be walked is retried
## shorter. Each pawn walks a little to one side of the line (up to [member spread_metres], from its random numbers) so a crowd marches
## as a band. It never finishes on its own: it stops being available once the pawn has arrived.
## Design: scaling spec 6.2.
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
	tag_requirements = TagQuery.shared([Tags.AI.STATE_IDLE])
	max_score = 0.15
	min_score = 0.15
	tick_interval_ticks = 60 # the safety net: it wakes when a leg ends (wake_on_path_end)


## A node is in point_group, and the pawn is further than arrive_radius from the nearest one: two conditions.
func own_conditions() -> Array[AICondition]:
	var list: Array[AICondition] = [
		AICompareCondition.make(StringName(AIInputs.GROUP_FOUND + String(point_group)), AICompareCondition.Comparison.EQUAL, 1.0),
		AICompareCondition.make(StringName(AIInputs.GROUP_DISTANCE + String(point_group)), AICompareCondition.Comparison.MORE_THAN,
			arrive_radius),
	]
	return list


func enter(_context: AIManager) -> void:
	_shorten = 0.0
	wake_on_path_end()


func tick(context: AIManager) -> Status:
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


func exit(context: AIManager, _reason: String) -> void:
	if context and context.controller:
		context.controller.stop()

