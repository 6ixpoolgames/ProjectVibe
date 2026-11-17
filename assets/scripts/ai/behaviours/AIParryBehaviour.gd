# Written by Claude (claude-opus-5-5), 2026-11-15. History: ai/CHANGELOG.md.
## Parries a swing coming at the pawn, some of the time ([member parry_chance]).
##
## The owner's request: AI pawns parry too, about 30% of swings, so a mass fight has some variety and parry gets tested under load.
## [br]
## How it hears about a swing: an enemy's MeleeAttackAbility, when it starts on the server, tells the AI of each pawn it may reach
## ([method AIContextComponent.note_incoming_attack]), which notes it and asks for a decision at once. Ordinary decisions come every
## 15 ticks, longer than a swing's windup, so without that the parry would usually come too late.
## [br]
## When it's available: a noted swing hasn't hit yet, its attacker is alive, and this swing's roll came up: two conditions. The roll
## is made from the swing's start tick and the attacker's pawn number, so each swing is rolled once, however many decisions happen
## during its windup, and a replay rolls the same.
## [br]
## What it does: looks at the attacker and presses parry (presses_action, so it's skipped while the parry is cooling down or locked
## out, for example mid-swing). It finishes two ticks later, and forgets the swing. ParryAbility does the rest.
class_name AIParryBehaviour
extends AIBehaviourBase

## How often it parries a swing coming at it, from 0 (never) to 1 (every one it can).
@export_range(0.0, 1.0, 0.01) var parry_chance := 0.3

const ROLL_SALT := 0x9A44


func _init() -> void:
	super()
	# Above every other behaviour in the samples (the heavy attack is 0.95), because a parry has to happen now or never.
	max_score = 0.97
	min_score = 0.97
	presses_action = &"parry"
	tick_interval_ticks = 60 # the safety net: it wakes two ticks after the press (wake_at)


## A swing is coming, and its roll came up: once per swing, from its start tick and its attacker's number.
func own_conditions() -> Array[AICondition]:
	var list: Array[AICondition] = [
		AICompareCondition.make(AIInputs.INCOMING_ATTACK, AICompareCondition.Comparison.EQUAL, 1.0),
		AIChanceCondition.make(parry_chance, ROLL_SALT, AIInputs.INCOMING_ATTACK_TICK, AIInputs.INCOMING_ATTACKER),
	]
	return list


var _started_tick := -1


func enter(context: AIContextComponent) -> void:
	_started_tick = context.current_tick
	wake_at(_started_tick + 2) # its one tick that matters (see tick())
	var hands := context.controller
	if hands == null or not is_instance_valid(context.incoming_attacker):
		return
	hands.stop()
	hands.look_at_point(context.incoming_attacker.global_position)
	hands.press(presses_action) # the setting, so a parry on another action works too


func tick(context: AIContextComponent) -> Status:
	# As AIAttackBehaviour: the press reaches the ability on the next input, so give it two ticks before finishing. tick() also runs
	# on the tick it starts.
	if context.current_tick - _started_tick < 2:
		wake_at(_started_tick + 2)
		return Status.RUNNING
	context.clear_incoming_attack()
	return Status.SUCCEEDED


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.stop_looking()
