## Written by Claude (claude-opus-5-5), 2026-11-15: parries a swing coming at the pawn, some of the time. The owner's request: AI pawns
## parry too, about 30% of swings, so a mass fight has some variety and parry gets tested under load.
##
## How it hears about a swing: an enemy's MeleeAttackAbility, when it starts on the server, tells the pawns it may reach
## (Pawn.notice_incoming_attack), and their AIContextComponent notes it and asks for a decision at once. Ordinary decisions come every
## 15 ticks, longer than a swing's windup, so without that the parry would usually come too late.
##
## When it's available: a noted swing hasn't hit yet, its attacker is alive, and this swing's roll came up (parry_chance). The roll is
## made from the swing's start tick and the attacker, so each swing is rolled once, however many decisions happen during its windup,
## and a replay rolls the same.
##
## What it does: looks at the attacker and presses parry (presses_action, so it's skipped while the parry is cooling down or locked
## out, for example mid-swing). It finishes on its next tick, and forgets the swing. ParryAbility does the rest.
class_name AIParryBehaviour
extends AIBehaviourBase

## How often it parries a swing coming at it, from 0 (never) to 1 (every one it can).
@export_range(0.0, 1.0, 0.01) var parry_chance := 0.3

const ROLL_SALT := 0x9A44


func _init() -> void:
	super()
	# GDScript note: above every other behaviour in the samples (the heavy attack is 0.95), because a parry has to happen now or never.
	max_score = 0.97
	min_score = 0.97
	presses_action = &"parry"


func is_available(context: AIContextComponent) -> bool:
	if not context.has_incoming_attack():
		return false
	# One roll per swing: from the tick it started and who swung. GDScript note: get_instance_id() differs between machines, but the
	# AI only runs on the server, so that's fine; the entity id would be needed if clients ran it.
	var salt := ROLL_SALT ^ (context.incoming_attacker.get_instance_id() & 0xFFFF)
	return context.random_unit_at(context.incoming_start_tick, salt) < parry_chance


var _started_tick := -1


func enter(context: AIContextComponent) -> void:
	_started_tick = context.current_tick
	var hands := context.controller
	if hands == null or not is_instance_valid(context.incoming_attacker):
		return
	hands.stop()
	hands.look_at_point(context.incoming_attacker.global_position)
	hands.press(presses_action) # Claude 2026-11-16 (wider audit): the setting, where "parry" was written in here whatever it said


func tick(context: AIContextComponent) -> Status:
	# As AIAttackBehaviour: the press reaches the ability on the next input, so give it two ticks before finishing. tick() also runs
	# on the tick it starts.
	if context.current_tick - _started_tick < 2:
		return Status.RUNNING
	context.clear_incoming_attack()
	return Status.SUCCEEDED


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.stop_looking()
