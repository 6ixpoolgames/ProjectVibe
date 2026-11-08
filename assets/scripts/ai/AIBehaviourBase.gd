## Written by Claude (claude-opus-5-5), 2026-11-09: the base for one AI behaviour, such as Wander or Chase. A child of the pawn's
## AIBehaviourManager. Pawn spec section 10.7.
##
## A behaviour is one concrete thing to do. Each holds its own checks, score and actions; the behaviour manager only judges between
## them (pawn spec 10.8). It acts only through the AI controller, the pawn's hands: context.controller.move_to(), press(), hold(),
## look_at_point(). It never touches abilities or the body directly (pawn spec section 3, rule 4).
##
## How to make one: extend this, set the settings below in the inspector or in _init(), and override any of:
##   is_available(context) -> bool    its own yes or no, after the manager's cheap checks
##   score(context) -> float          how much it wants to run now, from min_score to max_score
##   enter(context)                   once, when it starts
##   tick(context) -> Status          every tick while it runs. Return SUCCEEDED or FAILED to finish
##   exit(context, reason)            once, when it stops, whatever the reason. Clean up here, such as context.controller.stop()
##
## The behaviour's name is its node name, such as Wander. The fixed order and the random numbers read it, so give it a real name.
##
## Settings worth knowing (pawn spec 10.7):
##   - persistence, persistence_fade: from when it's chosen, its score gets persistence × the fade's value. + keeps it chosen, -
##     makes the AI prefer something else for a while. Empty fade: no persistence.
##   - interrupt_threshold, cannot_be_interrupted, min_run_ticks: what may replace it while it runs.
##   - score_jitter: a random offset on its score at each decision, for variety. -1 uses the manager's default_score_jitter.
class_name AIBehaviourBase
extends Node

enum Status { RUNNING, SUCCEEDED, FAILED }

## States it may run in, by node name, such as &"Idle". Empty: any state.
@export var allowed_states: Array[StringName] = []
## The highest score() can return. Used to skip it without running its code when it can't win.
@export var max_score := 0.5
## Optional: the lowest score() can return. Left at -inf it can't help skip others, but it's never wrong.
@export var min_score := -INF
## Skipped while the AI has no current target.
@export var needs_target := false
## A named action it presses, such as &"primary". Skipped while that action couldn't start.
@export var presses_action: StringName = &""
## Ticks after it ends before it can be chosen again. A hard rule, checked before any scoring.
@export_range(0, 36000, 1, "or_greater") var cooldown_ticks := 0
## Once chosen, ordinary decisions can't replace it for this many ticks. State changes and forces still can, if strong enough.
@export_range(0, 36000, 1, "or_greater") var min_run_ticks := 0
## While it runs, only events of this priority or higher can replace it: 0 for an ordinary decision, a state's priority for a state
## change, a force's priority for a forced state. 0: anything can.
@export var interrupt_threshold := 0
## Runs until it returns SUCCEEDED or FAILED, whatever happens, even if its state no longer allows it. Use sparingly.
@export var cannot_be_interrupted := false
## ± random offset on its score at each decision, for variety. -1: the manager's default_score_jitter.
@export var score_jitter := -1.0
## Added to its score from when it's chosen, times persistence_fade's value. +: tends to keep it chosen. -: prefers others for a while.
@export var persistence := 0.0
## How persistence fades over ticks. Empty: no persistence.
@export var persistence_fade: FadeProfile

## Set by the AIBehaviourManager.
var manager: AIBehaviourManager = null
var pawn: Pawn = null
## Worked out once by the manager: a hash of the name, for random numbers.
var name_hash := 0
## The tick it last started, and the tick it last ended (-1: never).
var started_tick := -1
var ended_tick := -1

# Scratch values for one decision, kept here so a decision creates no arrays or objects. Only the manager reads them.
var decision_persistence := 0.0
var decision_jitter := 0.0 # this decision's random offset
var decision_ceiling := 0.0
var decision_index := 0 # place in the fixed order
var warned_score_range := false

# Persistence, as three numbers: how far along the fade it was at the last change, that change's tick, and how fast it moves along.
# The amount now is worked out from these and the current tick, so nothing runs every tick.
var _persistence_running := false
var _persistence_along := 0.0
var _persistence_changed_tick := 0
var _persistence_speed := 1.0


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## Its own yes or no, after the manager's checks. The default: yes.
func is_available(_context: AIContextComponent) -> bool:
	return true


## How much it wants to run now. Keep it between min_score and max_score. The default: max_score.
func score(_context: AIContextComponent) -> float:
	return max_score


## Once, when it starts.
func enter(_context: AIContextComponent) -> void:
	pass


## Every tick while it runs. The default runs forever.
func tick(_context: AIContextComponent) -> Status:
	return Status.RUNNING


## Once, when it stops. reason says why, such as "decision", "interrupted", "succeeded", "failed" or "removed".
func exit(_context: AIContextComponent, _reason: String) -> void:
	pass


# --- Used by the manager ---


## True if it may run in this state.
func is_allowed_in(state_name: StringName) -> bool:
	return allowed_states.is_empty() or allowed_states.has(state_name)


## True while its cooldown hasn't finished.
func is_cooling_down(tick: int) -> bool:
	return cooldown_ticks > 0 and ended_tick >= 0 and tick - ended_tick < cooldown_ticks


## This behaviour's jitter amount: its own, or the manager's default when it's -1.
func effective_jitter() -> float:
	if score_jitter >= 0.0:
		return score_jitter
	return manager.default_score_jitter if manager else 0.0


## What persistence adds to its score at this tick.
func persistence_now(tick: int) -> float:
	if not _persistence_running or persistence == 0.0 or persistence_fade == null:
		return 0.0
	return persistence * persistence_fade.value_at(_persistence_ticks_along(tick))


## Starts persistence from the beginning of its fade. The manager calls this when the behaviour is chosen.
func start_persistence(tick: int) -> void:
	_persistence_running = true
	_persistence_along = 0.0
	_persistence_changed_tick = tick
	_persistence_speed = 1.0


## Moves persistence back along its fade by this many ticks, so it lasts longer. Negative: forward, so it ends sooner.
func add_persistence_ticks(ticks: float, tick: int) -> void:
	if not _persistence_running:
		return
	_persistence_along = maxf(0.0, _persistence_ticks_along(tick) - ticks)
	_persistence_changed_tick = tick


## How fast persistence moves along its fade from now on: 1.0 normally, 0.5 for half speed.
func set_persistence_speed(speed: float, tick: int) -> void:
	_persistence_along = _persistence_ticks_along(tick)
	_persistence_changed_tick = tick
	_persistence_speed = maxf(0.0, speed)


func _persistence_ticks_along(tick: int) -> float:
	return _persistence_along + (tick - _persistence_changed_tick) * _persistence_speed
