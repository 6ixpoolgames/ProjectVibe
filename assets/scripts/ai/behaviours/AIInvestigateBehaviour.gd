## Written by Claude (claude-opus-5-5), 2026-11-09: walks over to see what something half-noticed was. Pawn spec section 10.7. Allowed
## in Alert by default.
##
## It scores high while the most aware entry in memory isn't certain yet, and walks, without sprinting, to that entry's last
## known position. If the position moves more than repath_distance (the target was seen again somewhere else), it heads for the new
## one. It succeeds on arriving, and fails if there's no way there. Its cooldown stops it walking to the same spot over and over.
##
## It's only available while something uncertain is remembered: Search handles enemies it became certain of.
## Claude 2026-11-09, step 10: or while an unknown attacker hit the pawn within hit_memory_ticks: then it walks to where the hit
## came from, with no memory entry (no damage sense, the owner's call).
class_name AIInvestigateBehaviour
extends AIBehaviourBase

## How far, in metres, the last known position must move before it heads for the new one.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 2.0
## How close, in metres, counts as arrived.
@export_range(0.1, 10.0, 0.1, "or_greater") var arrive_distance := 1.0
## Claude 2026-11-09: how long after being hit by an unknown attacker it may still go to where the hit came from, in ticks.
@export_range(0, 36000, 1, "or_greater") var hit_memory_ticks := 300

var _goal := Vector3.ZERO


func _init() -> void:
	super()
	allowed_states = [&"Alert"]
	max_score = 0.5
	min_score = max_score # a fixed score, so it can help skip others
	cooldown_ticks = 120
	tick_interval_ticks = 5 # Claude 2026-11-09: it only needs to notice arriving, or the position moving


# Only for something half-noticed: an uncertain most aware entry, or a recent hit from an unknown attacker. Its score is always
# max_score, so it doesn't need a score() of its own.
func is_available(context: AIContextComponent) -> bool:
	return _point_of_interest(context) != null


func enter(context: AIContextComponent) -> void:
	context.controller.hold(&"sprint", false)
	var point: Variant = _point_of_interest(context)
	if point != null:
		_go(context, point)


func tick(context: AIContextComponent) -> Status:
	var point: Variant = _point_of_interest(context)
	if point == null:
		return Status.FAILED # forgotten
	if point.distance_to(_goal) > repath_distance:
		_go(context, point)
	if context.controller.is_following_order():
		return Status.RUNNING
	var offset := _goal - pawn.global_position
	offset.y = 0.0
	return Status.SUCCEEDED if offset.length() <= arrive_distance else Status.FAILED


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.stop()


func _go(context: AIContextComponent, point: Vector3) -> void:
	_goal = point
	context.controller.move_to(point)


# The uncertain most aware entry's last known position, or else where an unknown attacker hit from; null when there's neither.
func _point_of_interest(context: AIContextComponent) -> Variant:
	var index := context.most_aware_index()
	if index >= 0 and not context.memory.is_certain_at(index):
		return context.memory.last_known_position_at(index)
	return context.unknown_hit_point(hit_memory_ticks)
