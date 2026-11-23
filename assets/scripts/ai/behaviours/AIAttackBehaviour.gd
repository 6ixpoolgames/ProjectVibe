# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Attacks the current target once it's close enough: a swing, a shot, any attack on its action.
##
## Allowed in Combat. Available when the target's last known position is within the attack's reach ([method AbilityBase.attack_reach]
## of the ability on [member AIBehaviourBase.presses_action]) minus [member approach_margin]: the AI steps a little closer than the real
## reach so the attack lands. Chase brings the pawn in (score 0.8); this scores 0.9 and takes over at that distance. It faces the target,
## holds the attack's action through the attack, sleeps until it ends, then finishes. Its interrupt_threshold (15) stops an ordinary
## decision cutting an attack off. A second Attack with another action and a higher score gives a special or ranged attack (the sample
## goblins' HeavyAttack and Shoot). A [member min_distance] keeps a ranged one from firing at point blank, so the melee attacks take over
## there ([AIKeepDistanceBehaviour] hangs back between shots). Design: pawn spec 10.7 (step 9), 8.6, 8.20 and 8.24; scaling spec 6.2.
class_name AIAttackBehaviour
extends AIBehaviourBase

## How much closer than the attack's range the AI steps before attacking, in metres.
@export_range(0.0, 5.0, 0.05, "or_greater") var approach_margin := 0.3
## The nearest the target may be for this attack, in metres; 0: no limit. For a ranged attack, set it to the Keep Distance behaviour's
## melee_distance, so a target that close is met with melee instead.
@export_range(0.0, 50.0, 0.1, "or_greater") var min_distance := 0.0
# presses_action (AIBehaviourBase) is the action that starts the attack; the behaviour manager also reads it to skip an attack it couldn't press.

var _attack: AbilityBase = null
var _started_tick := 0
var _hold_from_tick := -1 # the tick to start holding on, when a press had to wait a tick; -1: none waiting


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_COMBAT])
	needs_target = true
	presses_action = &"primary"
	max_score = 0.9
	min_score = 0.9
	interrupt_threshold = 15
	tick_interval_ticks = 60 # the safety net: it wakes for the press and when the swing ends


## Close enough: the target is within the attack's reach - [member approach_margin], and no nearer than [member min_distance] if
## that's set. With no attack on presses_action nothing is close enough, so it never runs. If the attack's range changes during play, call [method AIBehaviourBase.rebuild_conditions].
func own_conditions() -> Array[AICondition]:
	var attack := _find_attack()
	var reach := attack.attack_reach() - approach_margin if attack else -1.0
	var list: Array[AICondition] = [AICompareCondition.make(AIInputs.TARGET_DISTANCE, AICompareCondition.Comparison.AT_MOST, reach)]
	if min_distance > 0.0:
		list.append(AICompareCondition.make(AIInputs.TARGET_DISTANCE, AICompareCondition.Comparison.AT_LEAST, min_distance))
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


# The pawn's attack on presses_action (an ability with a reach), found once.
func _find_attack() -> AbilityBase:
	if _attack == null and pawn and pawn.ability_manager:
		for ability in pawn.ability_manager.get_abilities():
			if ability.trigger_action == presses_action and ability.attack_reach() > 0.0:
				_attack = ability
				break
	return _attack
