# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Walks over to see what something half-noticed was.
##
## Allowed in Alert. Available while the most aware memory entry isn't certain yet (Search handles certain ones), or while an unknown
## attacker hit the pawn within [member hit_memory_ticks], when it walks to where the hit came from. It walks, without sprinting, to the
## entry's last known position and heads for a new one if that moves more than [member repath_distance]. It succeeds on arriving and
## fails if there's no way there; its cooldown stops it walking to the same spot over and over.
## Design: pawn spec 10.7.
class_name AIInvestigateBehaviour
extends AIBehaviourBase

## How far, in metres, the last known position must move before it heads for the new one.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 2.0
## How close, in metres, counts as arrived.
@export_range(0.1, 10.0, 0.1, "or_greater") var arrive_distance := 1.0
## How long after being hit by an unknown attacker it may still go to where the hit came from, in ticks.
@export_range(0, 36000, 1, "or_greater") var hit_memory_ticks := 300

var _goal := Vector3.ZERO


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_ALERT])
	max_score = 0.5
	min_score = max_score # a fixed score, so it can help skip others
	cooldown_ticks = 120 # after it finishes, Look Toward gets its turn again, even while Look Toward's own persistence holds it back
	tick_interval_ticks = 5 # it only needs to notice arriving, or the position moving


## Only for something half-noticed: an uncertain most aware entry, or a recent hit from an attacker it doesn't remember. Either will do.
func own_conditions() -> Array[AICondition]:
	return AIInputs.half_noticed_conditions(hit_memory_ticks)


func enter(context: AIContextComponent) -> void:
	context.controller.hold(&"sprint", false)
	var point: Variant = context.point_of_interest(hit_memory_ticks)
	if point != null:
		_go(context, point)


func tick(context: AIContextComponent) -> Status:
	var point: Variant = context.point_of_interest(hit_memory_ticks)
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
