# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Attacks the current target once it's close enough: a swing, a shot, any attack on its action.
##
## Allowed in Combat. Available when the target's last known position is within the attack's reach ([method AbilityBase.attack_reach]
## of the ability on [member AIBehaviourDefinition.presses_action]) minus [member AIAttackDefinition.approach_margin]: the AI steps a
## little closer than the real reach so the attack lands. Chase brings the pawn in (score 80); this scores 90 and takes over at that
## distance. Its steps: LookAt the target, and a Hold of the attack's action through the attack (with a fresh press, so a swing held
## through the one before still starts with a press); it sleeps until the attack ends, then finishes. Its interrupt_threshold (15)
## stops an ordinary decision cutting an attack off. A second Attack with another action and a higher score gives a special or
## ranged attack (the sample goblins' HeavyAttack and Shoot). A [member AIAttackDefinition.min_distance] keeps a ranged one from firing
## at point blank, so the melee attacks take over there ([AIKeepDistanceBehaviour] hangs back between shots). Design: pawn spec 10.7
## (step 9), 8.6, 8.20 and 8.24; scaling spec 6.2.
class_name AIAttackBehaviour
extends AIBehaviourBase

# presses_action (AIBehaviourBase) is the action that starts the attack; the behaviour manager also reads it to skip an attack it couldn't press.

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AIAttackDefinition = null
var _attack: AbilityBase = null
var _started_tick := 0 # the tick its hold began


func make_default_definition() -> AIBehaviourDefinition:
	return AIAttackDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AIAttackDefinition


## Close enough: the target is within the attack's reach - [member AIAttackDefinition.approach_margin], and no nearer than [member AIAttackDefinition.min_distance] if
## that's set. With no attack on presses_action nothing is close enough, so it never runs. If the attack's range changes during play, call [method AIBehaviourBase.rebuild_conditions].
func own_conditions() -> Array[AICondition]:
	var attack := _find_attack()
	var reach := attack.attack_reach() - _kind_settings.approach_margin if attack else -1.0
	var list: Array[AICondition] = [AICompareCondition.make(AIInputs.TARGET_DISTANCE, AICompareCondition.Comparison.AT_MOST, reach)]
	if _kind_settings.min_distance > 0.0:
		list.append(AICompareCondition.make(AIInputs.TARGET_DISTANCE, AICompareCondition.Comparison.AT_LEAST, _kind_settings.min_distance))
	return list


func make_steps() -> Array[Step]:
	return [made_step(LookAtStep, &"LookAt"), made_step(HoldStep, &"Hold", {"fresh_press": true})]


func enter(context: AIManager) -> void:
	if context.has_target():
		start_step(&"LookAt", {"target": context.current_target, "offset": Vector3(0.0, 1.0, 0.0)})
	else:
		var index := context.current_target_index()
		if index >= 0:
			start_step(&"LookAt", {"target": null, "point": context.memory.last_known_position_at(index) + Vector3(0.0, 1.0, 0.0)})
	wake_on_action_end(settings.presses_action)
	# Held, not pressed once: a swing keeps turning toward its target only while its action is held (TurnToFaceStep). The hold begins a
	# tick late if the last input still held it (the swing before ended this tick), so it starts with a press.
	var hold := start_step(&"Hold", {"action": settings.presses_action}) as HoldStep
	_started_tick = hold.hold_from_tick() if hold else context.current_tick
	wake_at(_started_tick + 2)


func tick(context: AIManager) -> Status:
	# The press reaches the ability on the next input; give it two ticks to start before checking whether it's over.
	if context.current_tick - _started_tick < 2:
		wake_at(_started_tick + 2)
		return Status.RUNNING
	# Any swing on the action, since the manager may have picked another, such as the next swing of a combo. Asked of the manager,
	# which looks at its running abilities only.
	if pawn.ability_manager and pawn.ability_manager.is_action_running(settings.presses_action):
		return Status.RUNNING
	return Status.SUCCEEDED # its steps end with it, so the action is let go and the next attack is a fresh press


# The pawn's attack on presses_action (an ability with a reach), found once.
func _find_attack() -> AbilityBase:
	if _attack == null and pawn and pawn.ability_manager:
		for ability in pawn.ability_manager.get_abilities():
			if ability.settings.trigger_action == settings.presses_action and ability.attack_reach() > 0.0:
				_attack = ability
				break
	return _attack
