## Written by Claude (claude-opus-5-5), 2026-11-03: example behaviour. Walk to where a pawn was last seen.
## Shows the common pattern: read memory in is_available/score, act through context in enter/tick, clean up in exit.
##  - available when memory holds a "pawn_seen" fact this behaviour hasn't checked out yet, and the pawn can move
##  - score = that fact's confidence x score_weight, so it fades in priority as the memory fades
##  - succeeds on arrival and marks the fact as investigated (in fact.data), so it doesn't go back to the
##    same sighting forever. A newer sighting of that pawn (fact refreshed later) makes it worth investigating again.
extends AIBehaviourComponentBase
class_name InvestigateBehaviour

@export var fact_type: StringName = &"pawn_seen" ## which memory facts to investigate
@export var score_weight: float = 1.0 ## score = fact confidence x this
@export var min_confidence: float = 0.2 ## ignore memories fainter than this
@export var arrive_distance: float = 1.5 ## metres from the spot that count as "arrived"
@export var repath_distance: float = 2.0 ## if the remembered spot moves this far, re-issue the move

var _target: AIMemoryFact = null
var _movingTo: Vector3


func _init() -> void:
	cooldown = 2.0
	wake_on_facts = [&"pawn_seen"]


func is_available(context: AIContext) -> bool:
	return context.can_move() and _pick_fact(context) != null


func score(context: AIContext) -> float:
	var fact := _pick_fact(context)
	return fact.confidence * score_weight if fact else 0.0


func enter(context: AIContext) -> void:
	_target = _pick_fact(context)
	_movingTo = _target.position
	context.move_to(_movingTo)


func tick(context: AIContext, _delta: float) -> Status:
	if _target == null:
		return Status.FAILED
	if _target.position.distance_to(_movingTo) > repath_distance: #the memory was updated with a new spot
		_movingTo = _target.position
		context.move_to(_movingTo)
	if context.get_position().distance_to(_movingTo) <= arrive_distance:
		_target.data["investigated_at"] = _target.lastTime
		return Status.SUCCEEDED
	if not context.is_moving(): #controller gave up (unreachable spot)
		_target.data["investigated_at"] = _target.lastTime
		return Status.FAILED
	return Status.RUNNING


func exit(context: AIContext, _reason: ExitReason) -> void:
	context.stop_moving()
	_target = null


#the most confident fact of fact_type that is new since we last investigated it
func _pick_fact(context: AIContext) -> AIMemoryFact:
	if context.memory == null:
		return null
	var best: AIMemoryFact = null
	for fact in context.memory.get_facts(fact_type, min_confidence):
		if fact.lastTime <= fact.data.get("investigated_at", -1.0):
			continue
		if best == null or fact.confidence > best.confidence:
			best = fact
	return best
