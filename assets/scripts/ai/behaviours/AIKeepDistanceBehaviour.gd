# Written by Claude (claude-opus-5-5), 2026-11-18. History: ai/CHANGELOG.md.
## Hangs back at shooting distance from the current target: a ranged pawn's way of moving in a fight, in place of Chase.
##
## Allowed in Combat while a ranged attack has shots left (the status.has_ammo.ranged tag). Available only to a pawn with a ranged attack
## (an ability in [member ranged_tag]'s group with a reach, [method AbilityBase.attack_reach]), and only while the target is at least
## [member melee_distance] away. While the target is seen it gives one persistent order, [method AIController.keep_distance]: the
## controller keeps [member reach_fraction] of that attack's reach from it, closing in or backing away, and stands facing it. Once the
## target hasn't been seen for [member lost_after_ticks] it walks to that distance from where it was last seen. Scored 0.85, above Chase (0.8), so a ranged pawn hangs back instead of running in; the Shoot behaviour
## (an [AIAttackBehaviour] on the ranged attack's action, scored higher) fires whenever the shot is ready. Once the target closes within
## melee_distance it isn't available, so Chase and the melee attacks take over; give Shoot the same distance as its
## [member AIAttackBehaviour.min_distance] so the pawn melees rather than shooting at point blank. Design: pawn spec 8.24.
# REFACTOR: the sprint action's name, &"sprint", is written in, as in Chase, Search and Investigate. See CHANGELOG.md.
class_name AIKeepDistanceBehaviour
extends AIBehaviourBase

## The group of ability it keeps distance for: any ability tagged with it that has a reach. Ranged combat by default.
@export var ranged_tag: StringName = Tags.ABILITY.COMBAT_RANGED
## Where it stands, as a fraction of the ranged attack's reach from the target: 0.7 of a 14 m bolt is 9.8 m.
@export_range(0.1, 1.0, 0.05) var reach_fraction := 0.7
## How far, in metres, from that distance it may drift before it walks again. It walks until within half of this.
@export_range(0.1, 20.0, 0.1, "or_greater") var band := 1.5
## Closer than this, in metres, it gives up keeping distance and the melee behaviours take over.
@export_range(0.0, 50.0, 0.1, "or_greater") var melee_distance := 4.0
## On: it sprints while the target is beyond the ranged attack's reach. Sprint's own cooldown decides when it actually sprints.
@export var sprint_to_close := true
## Ticks since the target was last seen after which it keeps its distance from where it was last seen (at 60 a second).
@export_range(0, 600, 1, "or_greater") var lost_after_ticks := 30
## Ticks between new paths while it walks.
@export_range(1, 600, 1, "or_greater") var repath_ticks := 20
## How far, in metres, the spot it walks to must move before a new path is found early.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 1.5

var _ranged: AbilityBase = null
var _hands: AIController = null
var _memory: AIMemory = null
var _goal := Vector3.ZERO
var _keeping_from: Node3D = null # the target it told the controller to keep its distance from; null while it uses the last known spot
var _sprinting := false


func _init() -> void:
	super()
	# Only in Combat, and only while a ranged attack has shots left (its has_charges_tag): out of shots, Chase takes over.
	tag_requirements = TagQuery.shared([Tags.AI.STATE_COMBAT, Tags.STATUS.HAS_AMMO_RANGED])
	tags = [Tags.AI.STANCE_RANGED]
	needs_target = true
	max_score = 0.85
	min_score = 0.85
	tick_interval_ticks = 5 # the AI controller follows the path every tick; this only re-aims


## Has a ranged attack, and the target is at least [member melee_distance] away: one condition. With no ranged attack the condition can
## never pass. If its abilities change during play, call [method AIBehaviourBase.rebuild_conditions].
func own_conditions() -> Array[AICondition]:
	var least := melee_distance if find_ranged_attack() else AIInputs.FAR * 2.0
	var list: Array[AICondition] = [AICompareCondition.make(AIInputs.TARGET_DISTANCE, AICompareCondition.Comparison.AT_LEAST, least)]
	return list


## The metres from the target it stands at: [member reach_fraction] of its ranged attack's reach; 0 without one.
func preferred_distance() -> float:
	var ranged := find_ranged_attack()
	return ranged.attack_reach() * reach_fraction if ranged else 0.0


## The pawn's ranged attack: the first ability in [member ranged_tag]'s group with a reach, found once. Null if it has none.
func find_ranged_attack() -> AbilityBase:
	if _ranged == null and pawn and pawn.ability_manager:
		for ability in pawn.ability_manager.get_abilities():
			if TagRegistry.matches(ability.category_mask, ranged_tag) and ability.attack_reach() > 0.0:
				_ranged = ability
				break
	return _ranged


func enter(context: AIManager) -> void:
	_hands = context.controller
	_memory = context.memory
	_keeping_from = null
	_goal = Vector3.INF
	_set_sprint(false)


func tick(context: AIManager) -> Status:
	var index := context.current_target_index()
	if index < 0:
		return Status.FAILED # the target is gone
	var target := context.current_target
	var seen := is_instance_valid(target) and _memory.ticks_since_seen_at(index, context.current_tick) <= TickDriver.ticks_at_rate(lost_after_ticks)
	var there := target.global_position if seen else _memory.last_known_position_at(index)
	var away := pawn.global_position - there
	away.y = 0.0
	var distance := away.length()
	var preferred := preferred_distance()
	if seen:
		if _keeping_from != target:
			_keeping_from = target
			_hands.keep_distance(target, preferred, band, Vector3(0.0, 1.0, 0.0), repath_ticks, repath_distance)
	else:
		var direction := away / distance if distance > 0.01 else pawn.global_basis.z
		var goal := there + direction * preferred
		if _keeping_from != null or goal.distance_to(_goal) > repath_distance:
			# Out of sight: one walk to its distance from where it was last seen, given again only if that spot moves.
			_keeping_from = null
			_goal = goal
			_hands.move_to(goal)
			_hands.look_at_point(there + Vector3(0.0, 1.0, 0.0))
	# Sprints to close in while beyond the attack's reach; standing by, never.
	var standing := _keeping_from != null and _hands.is_standing_by()
	_set_sprint(sprint_to_close and not standing and distance > preferred / maxf(reach_fraction, 0.01))
	return Status.RUNNING


func exit(context: AIManager, _reason: String) -> void:
	if context.controller:
		context.controller.hold(&"sprint", false)
		context.controller.stop()
		context.controller.stop_looking()
	_sprinting = false


func _set_sprint(on: bool) -> void:
	if on != _sprinting:
		_sprinting = on
		_hands.hold(&"sprint", on)
