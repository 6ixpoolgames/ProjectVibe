# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Swings at the current target once it's close enough.
##
## Pawn spec section 10.7, step 9. Allowed in Combat by default. It's available when the current target's last known position is
## within the pawn's MeleeAttack attack_range minus [member approach_margin]: the AI steps a little closer than the attack's real
## reach, so the swing is more likely to land (the owner's call). Changing the attack's range changes both. Chase brings the pawn
## in; this scores higher (0.9 against 0.8), so it takes over at that distance.
## [br]
## It faces the target, holds the attack's action ([member AIBehaviourBase.presses_action]) through the swing, and finishes when the
## swing is over. The first tick held is the press, which is a request: the ability manager picks what it starts (the normal swing,
## or the next swing of a combo), and this waits for whichever runs on that action. Holding keeps the swing turning toward its
## target (TurnToFaceStep, pawn spec 8.20). A second Attack behaviour with presses_action set to another action, and a higher score,
## uses a special attack whenever it's ready (faction_arena_sample's goblins). Its interrupt_threshold (15) keeps an ordinary
## decision from cutting it off mid-swing; the swing itself follows the ability rules (pawn spec 8.6).
# REFACTOR: it finds its reach only on a MeleeAttackAbility, so a ranged or other attack can't use this behaviour. Asking the ability
# for its reach through AbilityBase would let one Attack behaviour drive any attack (extensible). See CHANGELOG.md.
class_name AIAttackBehaviour
extends AIBehaviourBase

## How much closer than the attack's range the AI steps before swinging, in metres.
@export_range(0.0, 5.0, 0.05, "or_greater") var approach_margin := 0.3
# The action that starts the swing is presses_action (AIBehaviourBase), which the behaviour manager also reads to skip an attack it
# couldn't press.

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


## Close enough: the target's last known position is within attack_range − [member approach_margin].
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
	# Held, not pressed once: a swing keeps turning toward its target only while its action is held (TurnToFaceStep, pawn spec 8.20). The first tick held is the press, so if the pawn's last input still had it held (the swing before ended this
	# very tick), it's let go for one tick first: held twice in a row is no press, and the swing would never start.
	_started_tick = context.current_tick
	if pawn.controller_manager and pawn.controller_manager.held_actions & InputActions.mask_of(presses_action) != 0:
		hands.hold(presses_action, false)
		_hold_from_tick = context.current_tick + 1
	else:
		hands.hold(presses_action, true)
		_hold_from_tick = -1


func tick(context: AIContextComponent) -> Status:
	_look_at_target(context)
	# The press that had to wait a tick (see enter()).
	if _hold_from_tick >= 0:
		if context.current_tick < _hold_from_tick:
			return Status.RUNNING
		context.controller.hold(presses_action, true)
		_hold_from_tick = -1
		_started_tick = context.current_tick
		return Status.RUNNING
	# The press reaches the ability on the next input; give it two ticks to start before checking whether it's over.
	if context.current_tick - _started_tick < 2:
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
