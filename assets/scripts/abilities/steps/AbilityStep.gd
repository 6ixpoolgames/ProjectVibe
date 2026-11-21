# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## One step of an ability, such as a windup, a turn or a swing: a child node of the ability.
##
## Steps start when the ability does ([member starts_first]) or when another finishes ([member starts_when_finished]), and several can
## run at once. Extend it and override [method enter], [method tick] (RUNNING, DONE or FAILED) and [method exit]; the ability ends when
## no step with [member keeps_ability_running] is left. A step started during a tick enters at once and gets its first tick on the next.
## [br][br]Rollback: [member running] and [member step_ticks] live in the ability's step_state and roll back; any other state must be
## listed in [method get_rollback_properties], because a rollback restores values without calling [method enter] or [method exit].
## Design: pawn spec 8.20.
class_name AbilityStep
extends Node

enum Status {
	RUNNING, ## still going
	DONE, ## finished: the steps in starts_when_finished start
	FAILED, ## couldn't do its job: the whole ability ends
}

## On: it starts when its ability starts. With no step marked, the ability's first step starts.
@export var starts_first := false
## The steps that start when this one is done (not when it fails or is cancelled). Other steps of the same ability.
@export var starts_when_finished: Array[NodePath] = []
## How long it runs, in ticks at 60 a second (converted for the match's tick rate). 0: until tick() says DONE.
@export_range(0, 600, 1, "or_greater") var length_ticks := 0
## While it runs, how strong a starting ability (or a hit's knockback) must be to cancel its ability. -1: the ability's own
## interrupt_threshold. With several steps running, the strictest counts.
@export var interrupt_threshold := -1
# For a step during which hits can't land, give it an InvulnerabilityInterceptor child (pawn spec 8.23).
## On: it ends on the first tick its action isn't held (reason "released") and its next steps start as if it were done. Held input is
## rolled-back input, so server, prediction and replay agree.
@export var ends_when_released := false
## The action that must stay held. Empty: its ability's trigger_action. With neither, it's never released.
@export var while_held: StringName = &""
## On: its ability keeps running while this step does. Off for a step that only goes along (a turn through a swing): once only such
## steps are left, the ability ends and they stop with "done".
@export var keeps_ability_running := true

# State that rolls back, kept in the ability's step_state: 0 while not running, step_ticks + 1 while running.
## True while it runs.
var running: bool:
	get:
		return index >= 0 and ability != null and ability.step_state[index] > 0
	set(value):
		if index >= 0 and ability != null:
			ability.set_step_value(index, 1 if value else 0)
## Ticks counted since it started (those [method counts_this_tick] allowed); in [method tick], the ticks before this one. 0 when not running.
var step_ticks: int:
	get:
		return ability.step_state[index] - 1 if running else 0
	set(value):
		if running:
			ability.set_step_value(index, maxi(value, 0) + 1)
## Its place in its ability's steps (and step_state), set when its ability finds it; -1 before.
var index := -1

## Set by its ability.
var ability: AbilityBase = null
var pawn: Pawn = null
## starts_when_finished, as steps, found once by its ability.
var next_steps: Array[AbilityStep] = []
## while_held's input bit (or its ability's trigger_action's), worked out once by setup_hold(). 0: no action to hold.
var hold_bit := 0


func _init() -> void:
	# Steps do nothing on their own; the ability runs them on the pawn's tick.
	set_process(false)
	set_physics_process(false)


## The properties on this step that roll back: none by default. A step that keeps more lists them here.
func get_rollback_properties() -> Array[String]:
	return []


## How long it runs, in this match's ticks; 0 if it runs until it says it's done.
func length() -> int:
	return TickDriver.ticks_at_rate(length_ticks) if length_ticks > 0 else 0


# --- Override these ---


## Once, when it starts.
func enter() -> void:
	pass


## Every tick it runs: RUNNING to go on, DONE when finished (its next steps start), FAILED to end the whole ability.
func tick(_dt: float) -> Status:
	return Status.RUNNING


## Once, when it stops; reason is "done", "released", "failed" or "cancelled" (its ability ended, an interrupt, or another step).
func exit(_reason: String) -> void:
	pass


## Whether this tick counts toward length_ticks. Always by default; a windup waiting for a turn says no.
func counts_this_tick() -> bool:
	return true


## Once, when its ability finds it: for working out settings (an input bit, say), not for state.
func setup() -> void:
	pass


## With ends_when_released, whether letting go may end it now. Yes by default; TurnToFace says no until its minimum turn.
func can_end_on_release() -> bool:
	return true


## True while its action is held this tick (always false with no action to hold).
func is_held() -> bool:
	return hold_bit != 0 and ability.held_actions() & hold_bit != 0


## Its ability calls this once, before setup(): which input bit to watch.
func setup_hold() -> void:
	var action := while_held if while_held != &"" else ability.trigger_action
	hold_bit = InputActions.mask_of(action) if action != &"" else 0


## Where the weapon is during this step, as an offset from the pawn's feet for this facing in radians; null: this step doesn't say.
## [method AbilityBase.weapon_point] collects them, so visuals need no work for a new pattern.
func weapon_point(_facing: float) -> Variant:
	return null


## How far through its length it is, 0 to 1, with how far the tick driver is toward the next tick, for smooth visuals. 0 with no length.
func progress() -> float:
	var total := length()
	if total <= 0:
		return 0.0
	var frac: float = TickDriver.get_interpolation_fraction() if counts_this_tick() else 0.0
	return clampf((float(step_ticks) + frac) / float(total), 0.0, 1.0)
