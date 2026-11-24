# Written by Claude (claude-opus-5-5), 2026-11-24. History: steps/CHANGELOG.md.
## One step on a timeline, such as a windup, a turn or a swing: a child node of what owns the timeline (pawn spec 16.7).
##
## A [StepTimeline] decides when steps start: at a tick, when another step starts or ends, or on a condition, so several can run at
## once and one step can run in several entries. Extend it and override [method enter], [method tick] (RUNNING, DONE or FAILED) and
## [method exit]; the owner ends when no step with [member keeps_owner_running] is left and nothing is due. A step started during a
## tick enters at once and gets its first tick on the next. Abilities use [AbilityStep], which adds cancel windows and ending on release.
## [br][br]Rollback: whether it runs and its count live in its timeline's state, which its owner rolls back; any other state must be
## listed in [method get_rollback_properties], because a rollback restores values without calling [method enter] or [method exit].
class_name Step
extends Node

enum Status {
	RUNNING, ## still going
	DONE, ## finished: the timeline entries that follow its end start
	FAILED, ## couldn't do its job: the whole run ends
}

## How long it runs, in ticks at 60 a second (converted for the match's tick rate). 0: until tick() says DONE.
@export_range(0, 600, 1, "or_greater") var length_ticks := 0
## On: its owner keeps running while this step does. Off for a step that only goes along (a turn through a swing): once only such
## steps are left, the owner's run ends and they stop with "done".
@export var keeps_owner_running := true

## True while it runs. Worked out from its timeline's state, which rolls back.
var running: bool:
	get:
		return timeline != null and timeline.running_entry_of(self) >= 0
## Ticks counted since it started (those [method counts_this_tick] allowed); in [method tick], the ticks before this one. 0 when not running.
var step_ticks: int:
	get:
		return timeline.step_ticks_of(self) if timeline else 0

## On: its timeline asks [method released_now] each tick. Off (the default), so steps that can't be released cost no call; a subclass
## that can end on release keeps it up to date.
var checks_release := false
## The timeline it's on, set when the timeline is built.
var timeline: StepTimeline = null
## The pawn its owner belongs to.
var pawn: Pawn = null


func _init() -> void:
	# Steps do nothing on their own; their timeline runs them on the pawn's tick.
	set_process(false)
	set_physics_process(false)


## The properties on this step that roll back: none by default. A step that keeps more lists them here.
func get_rollback_properties() -> Array[String]:
	return []


## How long it runs, in this match's ticks; 0 if it runs until it says it's done.
func length() -> int:
	return TickDriver.ticks_at_rate(length_ticks) if length_ticks > 0 else 0


## True if it should end now, before its tick, with "released" (which starts what follows it, as done does). Never by default;
## [AbilityStep] ends when its action is let go.
func released_now() -> bool:
	return false


## How far through its length it is, 0 to 1, with how far the tick driver is toward the next tick, for smooth visuals. 0 with no length.
func progress() -> float:
	var total := length()
	if total <= 0:
		return 0.0
	var frac: float = TickDriver.get_interpolation_fraction() if counts_this_tick() else 0.0
	return clampf((float(step_ticks) + frac) / float(total), 0.0, 1.0)


# --- Override these ---


## Once, when it starts.
func enter() -> void:
	pass


## Every tick it runs: RUNNING to go on, DONE when finished (what follows it in the timeline starts), FAILED to end the whole run.
func tick(_dt: float) -> Status:
	return Status.RUNNING


## Once, when it stops; reason is "done", "released", "failed" or "cancelled" (its owner ended, an interrupt, or another step).
func exit(_reason: String) -> void:
	pass


## Whether this tick counts toward length_ticks. Always by default; a windup waiting for a turn says no.
func counts_this_tick() -> bool:
	return true


## Once, when its timeline is built: for working out settings (an input bit, say), not for state.
func setup() -> void:
	pass
