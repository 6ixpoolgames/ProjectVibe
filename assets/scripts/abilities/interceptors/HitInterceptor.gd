# Written by Claude (claude-opus-5-5), 2026-11-17. History: abilities/CHANGELOG.md.
## Something that can stop a hit before it lands, while its ability or step runs (pawn spec 8.23).
##
## The same idea as an active ability in Unreal's Ability System examining incoming damage, built the way EffectApplier is: a node a
## designer adds.
## [br]
## How to use it: add one as a child of an ability (on while the ability runs) or of one of its steps (on while the step runs). Give
## it [EffectApplier] children with the ON_INTERCEPT trigger for what happens when it stops a hit: TARGET effects go on the attacker,
## in a hit of their own (the parry's push-back), SELF effects on this pawn (a reward for parrying, say).
## [br]
## When it acts ([member stage]):
## [br]- [b]MISS[/b]: the hit never reaches the pawn: invulnerability frames. The AI doesn't notice it, a swing can still catch the
##   pawn later in the same sweep, and harmful effects (a poison's tick) are refused too. [method intercept] isn't asked: while it's
##   on, nothing gets through. [method AbilityManager.is_invulnerable] asks these.
## [br]- [b]TURN_AWAY[/b]: the hit arrives (hit_arrived goes out, so the AI notices) and [method intercept] decides whether to stop
##   it. A parry or a shield block works this way.
## [br]
## Order: on each hit, the AbilityManager asks its active TURN_AWAY interceptors from the highest [member priority] down (tree order
## between equals), and the first that stops the hit ends it: hit_intercepted(hit, interceptor) goes out on the manager and its
## effects fire. A hit sent in reply to an interception ([member HitInfo.from_interception]) can't be turned away, so two parrying
## pawns don't bounce hits back and forth. Hits are decided on the server, so this runs there (or offline).
## [br]
## A new kind: extend this and override [method intercept] (and set stage in _init if it's MISS). Nothing else needs changing.
## [br]
## Room for stats (the owner's call: a stats pass comes with the game mechanics): every number an interceptor uses is read through
## one function ([method window_ticks] here, front_degrees_now() on the parry), so reading it from a stat later (a parry window from a
## Reflexes stat, say) changes that one function. intercept() returns a [enum Result], so a REDUCE result (take part of the damage,
## for a shield block scaled by a Guard stat) can be added beside PASS and STOP without changing the shape.
class_name HitInterceptor
extends Node

enum Stage { MISS, TURN_AWAY }
## PASS: let the hit through. STOP: none of its effects land.
enum Result { PASS, STOP }

## When it acts. See the class description.
@export var stage := Stage.TURN_AWAY
## Asked before those with a lower number. Equal numbers go in tree order.
@export var priority := 0
## How long it's on from the start of its ability's run (or its step's), in seconds. 0: the whole time its parent runs.
@export_range(0.0, 10.0, 0.01, "or_greater") var active_seconds := 0.0

## Set by the AbilityManager when it collects its abilities. step is null for one directly under its ability.
var ability: AbilityBase = null
var step: AbilityStep = null
var pawn: Pawn = null
## From its EffectApplier children with ON_INTERCEPT, collected by the AbilityManager: what the attacker gets (in a hit from this
## pawn) and what this pawn gets, when it stops a hit.
var on_intercept_effects: Array[Effect] = []
var on_intercept_self_effects: Array[Effect] = []
## What the debug drawing shows over an attacker whose hit this stopped.
var debug_label := "STOPPED"


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## True while it's on: its parent runs, and it's within active_seconds of the run's start. Read from timers that roll back, so a
## replay agrees about what was stopped.
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


## How many ticks it stays on from the start, or 0 for the whole run. active_seconds, converted the way abilities convert seconds.
func window_ticks() -> int:
	if active_seconds <= 0.0:
		return 0
	return ability.manager.ticks_for(active_seconds) if ability and ability.manager else 0


## TURN_AWAY only: whether to stop this hit. The base stops every hit that reaches it (a plain block); a parry only those from the
## front. Called on the server, only while is_active().
func intercept(_hit: HitInfo) -> Result:
	return Result.STOP


## Called by the AbilityManager after this stopped a hit: the attacker gets a hit of its own from this pawn, carrying the TARGET
## effects (it goes through the attacker's usual hit path, so its AI notices and a knockback cancels its swing), and this pawn
## gets the SELF effects.
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
	if not on_intercept_self_effects.is_empty() and pawn.effect_manager:
		pawn.effect_manager.apply_effects(on_intercept_self_effects, pawn, ability, hit)
