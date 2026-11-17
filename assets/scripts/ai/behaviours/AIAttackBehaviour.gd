# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Swings at the current target once it's close enough.
##
## Allowed in Combat. Available when the target's last known position is within the MeleeAttack's attack_range minus
## [member approach_margin]: the AI steps a little closer than the real reach so the swing lands. Chase brings the pawn in (score 0.8);
## this scores 0.9 and takes over at that distance. It faces the target, holds the attack's action ([member AIBehaviourBase.presses_action])
## through the swing, sleeps until it ends, then finishes. Its interrupt_threshold (15) stops an ordinary decision cutting a swing off.
## A second Attack with another action and a higher score gives a special attack (faction_arena_sample's goblins).
## Design: pawn spec 10.7 (step 9), 8.6 and 8.20; scaling spec 6.2.
# REFACTOR: it finds its reach only on a MeleeAttackAbility, so a ranged or other attack can't use this behaviour. Asking the ability
# for its reach through AbilityBase would let one Attack behaviour drive any attack (extensible). See CHANGELOG.md.
class_name AIAttackBehaviour
extends AIBehaviourBase

## How much closer than the attack's range the AI steps before swinging, in metres.
@export_range(0.0, 5.0, 0.05, "or_greater") var approach_margin := 0.3
# presses_action (AIBehaviourBase) is the action that starts the swing; the behaviour manager also reads it to skip an attack it couldn't press.

var _melee: MeleeAttackAbility = null
var _started_tick := 0
var _hold_from_tick := -1 # the tick to start holding on, when a press had to wait a tick; -1: none waiting


func _init() -> void:
	super()
	allowed_states = [&"Combat"]
	needs_target = true
	presses_action = &"primary"
	max_score = 0.9
	min_score = 0.9
	interrupt_threshold = 15
	tick_interval_ticks = 60 # the safety net: it wakes for the press and when the swing ends


## Close enough: the target is within attack_range âˆ’ [member approach_margin], one condition. With no MeleeAttack on presses_action
## nothing is close enough, so it never runs. If the attack's range changes during play, call [method AIBehaviourBase.rebuild_conditions].
func own_conditions() -> Array[AICondition]:
	var melee := _find_melee()
	var reach := melee.attack_range - approach_margin if melee else -1.0
	var list: Array[AICondition] = [AICompareCondition.make(AIInputs.TARGET_DISTANCE, AICompareCondition.Comparison.AT_MOST, reach)]
	return list


func enter(context: AIContextComponent) -> void:
	var hands := context.controller
	hands.stop()
	if context.has_target():
		hands.look_at_node(context.current_target, Vector3(0.0, 1.0, 0.0)) # followed at every input while it sleeps
	else:
		_look_at_target(context)
	wake_on_action_end(presses_action)
	# Held, not pressed once: a swing keeps turning toward its target only while its action is held (TurnToFaceStep). The first tick held
	# is the press, so if the last input still held it (the swing before ended this tick), it's let go for one tick first or no press happens.
	_started_tick = context.current_tick
	if pawn.controller_manager and pawn.controller_manager.held_actions & InputActions.mask_of(presses_action) != 0:
		hands.hold(presses_action, false)
		_hold_from_tick = context.current_tick + 1
		wake_at(_hold_from_tick)
	else:
		hands.hold(presses_action, true)
		_hold_from_tick = -1
		wake_at(_started_tick + 2)


func tick(context: AIContextComponent) -> Status:
	# The press that had to wait a tick (see enter()).
	if _hold_from_tick >= 0:
		if context.current_tick < _hold_from_tick:
			wake_at(_hold_from_tick)
			return Status.RUNNING
		context.controller.hold(presses_action, true)
		_hold_from_tick = -1
		_started_tick = context.current_tick
		wake_at(_started_tick + 2)
		return Status.RUNNING
	# The press reaches the ability on the next input; give it two ticks to start before checking whether it's over.
	if context.current_tick - _started_tick < 2:
		wake_at(_started_tick + 2)
		return Status.RUNNING
	# Any swing on the action, since the manager may have picked another, such as the next swing of a combo. Asked of the manager,
	# which looks at its running abilities only.
	if pawn.ability_manager and pawn.ability_manager.is_action_running(presses_action):
		return Status.RUNNING
	context.controller.hold(presses_action, false) # let go as the swing ends, so the next attack is a fresh press
	return Status.SUCCEEDED


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.hold(presses_action, false) # never left held
		context.controller.stop_looking()


func _look_at_target(context: AIContextComponent) -> void:
	var index := context.current_target_index()
	if index >= 0:
		context.controller.look_at_point(context.memory.last_known_position_at(index) + Vector3(0.0, 1.0, 0.0))


# The pawn's MeleeAttackAbility on presses_action, found once.
func _find_melee() -> MeleeAttackAbility:
	if _melee == null and pawn and pawn.ability_manager:
		for ability in pawn.ability_manager.get_abilities():
			if ability is MeleeAttackAbility and ability.trigger_action == presses_action:
				_melee = ability
				break
	return _melee
