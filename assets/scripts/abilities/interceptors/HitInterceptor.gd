# Written by Claude (claude-opus-5-5), 2026-11-17. History: abilities/CHANGELOG.md.
## Something that can stop a hit before it lands, while its ability or step runs (pawn spec 8.23).
##
## Add one as a child of an ability (on while it runs) or of one of its steps (on while the step runs), with [EffectApplier] children
## on the ON_INTERCEPT trigger for what happens when it stops a hit: TARGET effects go on the attacker in a hit of their own (a parry's
## push-back), SELF effects on this pawn. At [member stage] MISS the hit never arrives (invulnerability frames, harmful effects refused
## too); at TURN_AWAY it arrives and [method intercept] decides (a parry, a block). A new kind overrides [method intercept].
## [br][br]Hits are decided on the server, so this runs there (or offline). The manager asks active TURN_AWAY interceptors from the
## highest [member priority] down; the first to stop the hit ends it. A reply to an interception ([member HitInfo.from_interception])
## can't be turned away, so two parrying pawns don't bounce hits back and forth.
class_name HitInterceptor
extends Node

enum Stage { MISS, TURN_AWAY }
## PASS: let the hit through. STOP: none of its effects land.
enum Result { PASS, STOP }

## When it acts: MISS (the hit never arrives) or TURN_AWAY ([method intercept] decides).
@export var stage := Stage.TURN_AWAY
## Asked before those with a lower number. Equal numbers go in tree order.
@export var priority := 0
## How long it's on from the start of its ability's run (or its step's), in seconds. 0: the whole time its parent runs.
@export_range(0.0, 10.0, 0.01, "or_greater") var active_seconds := 0.0

## Set by the AbilityManager when it collects its abilities. step is null for one directly under its ability.
var ability: AbilityBase = null
var step: AbilityStep = null
var pawn: Pawn = null
## From its ON_INTERCEPT EffectApplier children, collected by the manager: what the attacker gets (in a hit from this pawn) and what
## this pawn gets, when it stops a hit.
var on_intercept_effects: Array[Effect] = []
var on_intercept_self_effects: Array[Effect] = []
## What the debug drawing shows over an attacker whose hit this stopped.
var debug_label := "STOPPED"


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## True while it's on: its parent runs and it's within active_seconds of the run's start. Read from rolled-back timers, so a replay
## agrees about what was stopped.
func is_active() -> bool:
	if ability == null:
		return false
	var running: bool
	var ticks_in: int
	if step:
		running = step.running
		ticks_in = step.step_ticks
	else:
		running = ability.is_running_timed()
		ticks_in = ability.ticks_running()
	if not running:
		return false
	var window := window_ticks()
	return window <= 0 or ticks_in < window


## Ticks it stays on from the start (active_seconds at the match's rate); 0: the whole run.
func window_ticks() -> int:
	if active_seconds <= 0.0:
		return 0
	return TickDriver.seconds_to_ticks(active_seconds)


## TURN_AWAY only: whether to stop this hit. The base stops every hit (a plain block); a parry only those from the front. Server,
## only while [method is_active].
func intercept(_hit: HitInfo) -> Result:
	return Result.STOP


## Called by the manager after this stopped a hit: the attacker gets a hit of its own with the TARGET effects (through its usual hit
## path, so its AI notices and a knockback cancels its swing), and this pawn gets the SELF effects.
func respond(hit: HitInfo) -> void:
	var attacker := hit.attacker
	if not on_intercept_effects.is_empty() and is_instance_valid(attacker) and attacker != pawn and attacker.ability_manager:
		var back := HitInfo.new()
		back.attacker = pawn
		back.target = attacker
		back.ability = ability
		back.tick = hit.tick
		back.from_interception = true
		var away := attacker.global_position - pawn.global_position
		away.y = 0.0
		back.direction = away.normalized() if away.length_squared() > 0.0001 else Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw))
		back.effects = on_intercept_effects
		attacker.ability_manager.receive_hit(back)
	if not on_intercept_self_effects.is_empty() and pawn.status_manager:
		pawn.status_manager.apply_effects(on_intercept_self_effects, pawn, ability, hit)
