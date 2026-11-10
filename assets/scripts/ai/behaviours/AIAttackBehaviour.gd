## Written by Claude (claude-opus-5-5), 2026-11-09: swings at the current target once it's close enough. Pawn spec section 10.7,
## step 9. Allowed in Combat by default.
##
## It's available when the current target's last known position is within the pawn's MeleeAttack attack_range minus
## approach_margin: the AI steps a little closer than the attack's real reach, so the swing is more likely to land (the owner's
## call). Changing the attack's range changes both. Chase brings the pawn in; this scores higher (0.9 against 0.8), so it takes over
## at that distance.
##
## It faces the target, presses the attack's action once, and finishes when the swing is over. Claude 2026-11-09: the press is a
## request; the ability manager picks what it starts (the normal swing, or a follow-up when that can't), and this waits for whichever
## runs. A second Attack behaviour with attack_action and presses_action set to another action, and a higher score, uses a special
## attack whenever it's ready (faction_arena_sample's goblins). Its interrupt_threshold (15) keeps an
## ordinary decision from cutting it off mid-swing; the swing itself follows the ability rules (pawn spec 8.6).
class_name AIAttackBehaviour
extends AIBehaviourBase

## How much closer than the attack's range the AI steps before swinging, in metres.
@export_range(0.0, 5.0, 0.05, "or_greater") var approach_margin := 0.3
## The action that starts the swing.
@export var attack_action: StringName = &"primary"

var _melee: MeleeAttackAbility = null
var _started_tick := 0


func _init() -> void:
	super()
	allowed_states = [&"Combat"]
	needs_target = true
	presses_action = &"primary"
	max_score = 0.9
	min_score = 0.9
	interrupt_threshold = 15


## Close enough: the target's last known position is within attack_range − approach_margin.
func is_available(context: AIContextComponent) -> bool:
	var melee := _find_melee()
	var index := context.current_target_index()
	if melee == null or index < 0:
		return false
	var offset := context.memory.last_known_position_at(index) - pawn.global_position
	offset.y = 0.0
	return offset.length() <= melee.attack_range - approach_margin


func enter(context: AIContextComponent) -> void:
	var hands := context.controller
	hands.stop()
	_look_at_target(context)
	hands.press(attack_action)
	_started_tick = context.current_tick


func tick(context: AIContextComponent) -> Status:
	_look_at_target(context)
	# The press reaches the ability on the next input; give it two ticks to start before checking whether it's over.
	if context.current_tick - _started_tick < 2:
		return Status.RUNNING
	# Claude 2026-11-09: any swing on the action, since the manager may have picked a follow-up instead. Claude 2026-11-10: such as
	# the second swing of a combo, which a boost picks (pawn spec 8.11).
	var abilities: Array = pawn.ability_manager.get_abilities() if pawn.ability_manager else []
	for ability in abilities:
		if ability.trigger_action == attack_action and ability.is_running_timed():
			return Status.RUNNING
	return Status.SUCCEEDED


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.stop_looking()


func _look_at_target(context: AIContextComponent) -> void:
	var index := context.current_target_index()
	if index >= 0:
		context.controller.look_at_point(context.memory.last_known_position_at(index) + Vector3(0.0, 1.0, 0.0))


func _find_melee() -> MeleeAttackAbility:
	if _melee == null and pawn and pawn.ability_manager:
		for ability in pawn.ability_manager.get_abilities():
			if ability is MeleeAttackAbility and ability.trigger_action == attack_action:
				_melee = ability
				break
	return _melee
