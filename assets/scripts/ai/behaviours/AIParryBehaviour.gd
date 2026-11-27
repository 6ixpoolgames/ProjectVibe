# Written by Claude (claude-opus-5-5), 2026-11-15. History: ai/CHANGELOG.md.
## Parries a swing coming at the pawn, some of the time ([member AIParryDefinition.parry_chance]).
##
## Available when a noted swing hasn't hit yet, its attacker is alive, and this swing's roll came up (two conditions). An enemy's
## A MeleeAttackAbility (or a fired projectile, FireProjectileStep) tells the AI of an attack when it starts, on the server ([method AIManager.note_incoming_attack]), which asks
## for a decision at once: ordinary decisions come every 15 ticks, longer than a swing's windup. The roll comes from the swing's start
## tick and the attacker's pawn number, so each swing is rolled once and a replay rolls the same. Its steps look at the attacker and
## press parry ([member AIBehaviourDefinition.presses_action], so it's skipped while the parry is cooling down or locked out); it
## finishes two ticks later and forgets the swing; ParryAbility does the rest.
## Design: scaling spec 6.2.
class_name AIParryBehaviour
extends AIBehaviourBase

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AIParryDefinition = null
const ROLL_SALT := 0x9A44

var _started_tick := -1


func make_default_definition() -> AIBehaviourDefinition:
	return AIParryDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AIParryDefinition


## A swing is coming, and its roll came up: once per swing, from its start tick and its attacker's number.
func own_conditions() -> Array[AICondition]:
	var list: Array[AICondition] = [
		AICompareCondition.make(AIInputs.INCOMING_ATTACK, AICompareCondition.Comparison.EQUAL, 1.0),
		AIChanceCondition.make(_kind_settings.parry_chance, ROLL_SALT, AIInputs.INCOMING_ATTACK_TICK, AIInputs.INCOMING_ATTACKER),
	]
	return list


func make_steps() -> Array[Step]:
	return [made_step(LookAtStep, &"LookAt"), made_step(PressStep, &"Press")]


func enter(context: AIManager) -> void:
	_started_tick = context.current_tick
	wake_at(_started_tick + 2) # its one tick that matters (see tick())
	if not is_instance_valid(context.incoming_attacker):
		return
	start_step(&"LookAt", {"target": null, "point": context.incoming_attacker.global_position})
	start_step(&"Press", {"action": settings.presses_action}) # the setting, so a parry on another action works too


func tick(context: AIManager) -> Status:
	# As AIAttackBehaviour: the press reaches the ability on the next input, so give it two ticks before finishing. tick() also runs
	# on the tick it starts.
	if context.current_tick - _started_tick < 2:
		wake_at(_started_tick + 2)
		return Status.RUNNING
	context.clear_incoming_attack()
	return Status.SUCCEEDED
