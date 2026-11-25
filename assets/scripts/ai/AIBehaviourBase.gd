# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## The base for one AI behaviour, such as Wander or Chase: one concrete thing to do.
##
## A child of the pawn's [AIBehaviourManager], which only judges between behaviours. A behaviour holds its own conditions, score and
## actions, and acts only through the AI controller ([code]context.controller.move_to()[/code], [code]press()[/code]), never on
## abilities or the body. Extend it, set the settings below, and override [method own_conditions], [method enter], [method tick]
## (return SUCCEEDED or FAILED to finish) and [method exit]. Its node name is its name: the fixed order and the random numbers read
## it. Settings counted in ticks are written for 60 a second and converted where read ([code]TickDriver.ticks_at_rate[/code]).
## Design: pawn spec 10.7, scaling spec 6.2.
class_name AIBehaviourBase
extends Node

## What [method tick] returns: keep running, or finished well or badly.
enum Status { RUNNING, SUCCEEDED, FAILED }

## Off: never chosen, and a running one is replaced, as if it weren't there. The way an inherited scene switches off a behaviour it
## can't remove.
@export var enabled := true:
	set(value):
		enabled = value
		if manager:
			manager.inputs_changed() # C++ gets the brain again
## What it is, as tags such as &"ai.stance.melee": what score modifiers pick behaviours by ([member AIScoreModifier.applies_to]).
@export var tags: Array[StringName] = []:
	set(value):
		tags = value
		_tag_words_generation = -1
## When it may run: a query over the pawn's owned tags, such as any of ai.state.combat (the AI's state is a tag), or none of
## status.has_ammo. While it fails, the behaviour can't be chosen, and a running one is replaced at the next AI step. Empty: always.
@export var tag_requirements: TagQuery
## The highest score() can return. Lets the manager skip it without running its code when it can't win.
@export var max_score := 0.5
## Optional: the lowest score() can return. Left at -inf it can't help skip others, but it's never wrong.
@export var min_score := -INF
## Skipped while the AI has no current target.
@export var needs_target := false
## A named action it presses, such as &"primary". Skipped while that action couldn't start.
@export var presses_action: StringName = &""
## More conditions it needs, on top of its own ([method own_conditions]). All must pass. Made in the inspector: compare an input
## with a number, a random chance, or "any of".
@export var conditions: Array[AICondition] = []
## Optional: inputs that scale its score between min_score (or 0) and max_score, multiplied together. Empty: always max_score.
@export var score_curves: Array[AIScoreCurve] = []
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
## While it runs, [method tick] is called every this many ticks, and sooner when a wake-up it asked for happens (the longest it
## sleeps). Count time with context.current_tick, not by counting tick() calls. 1: every tick.
@export_range(1, 600, 1, "or_greater") var tick_interval_ticks := 1
## Added to its score from when it's chosen, times persistence_fade's value. +: tends to keep it chosen. -: prefers others for a while.
@export var persistence := 0.0
## How persistence fades over ticks. Empty: no persistence.
@export var persistence_fade: FadeProfile
## This pawn's own mask over [member persistence_fade], multiplied with it. Null: none. Set through
## [method AIBehaviourManager.set_persistence_mask] so C++ hears of it. A hook; nothing sets one yet.
var persistence_mask: FadeProfile = null

## Set by the AIBehaviourManager.
var manager: AIBehaviourManager = null
## The pawn this behaviour belongs to. Set by the AIBehaviourManager.
var pawn: Pawn = null
## Worked out once by the manager: a hash of the name, for random numbers.
var name_hash := 0
## The tick it last started (-1: never).
var started_tick := -1
## The tick it last ended (-1: never).
var ended_tick := -1
## The timing scope names for its is_available() and its tick(), such as &"ai.available.Chase" and &"ai.behaviour.Chase" (see
## [PerfScopes]). Made once by the manager, so timing makes no new names.
var perf_available_name: StringName = &""
## The timing scope name for its tick(), such as &"ai.behaviour.Chase". Made once by the manager.
var perf_tick_name: StringName = &""

# Scratch values for one decision, kept here so a decision creates no arrays or objects. Only the manager reads them.
var decision_persistence := 0.0
var decision_modifier := 0.0 # the score modifiers' sum for it, worked out when they or the owned tags change
var decision_blocked := false # a blocking score modifier counts for it
var decision_jitter := 0.0 # this decision's random offset
var decision_ceiling := 0.0
var decision_floor := 0.0 # -INF when min_score isn't set
var decision_available := false # is_available()'s answer this decision, once availability_checked is true
var availability_checked := false
var decision_score := 0.0 # score()'s answer this decision, once decision_scored is true
var decision_scored := false
var decision_index := 0 # place in the fixed order
var warned_score_range := false

## Wake-ups, read by the manager (see the class description). Cleared when it starts.
var wake_tick := -1 # wake_at's tick; -1: none
var wakes_on_path_end := false
var wakes_on_action: StringName = &""
var woken := false # an event it waits for happened since its last tick()

var _tag_words := PackedInt64Array()
var _tag_words_generation := -1
var _all_conditions: Array[AICondition] = []
var _conditions_built := false

# Persistence, as three numbers: how far along the fade it was at the last change, that change's tick, and how fast it moves along.
# The amount now is worked out from these and the current tick, so nothing runs every tick.
var _persistence_running := false
var _persistence_along := 0.0
var _persistence_changed_tick := 0
var _persistence_speed := 1.0


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## Its own yes or no, after the manager's checks: every condition passes ([method all_conditions]). The inputs they read were worked
## out for this decision by the behaviour manager. Overriding this with code works, but see [method has_own_code].
func is_available(context: AIManager) -> bool:
	var inputs := context.inputs
	for condition in all_conditions():
		if not condition.passes(inputs, context, name_hash):
			return false
	return true


## How much it wants to run now, between min_score and max_score: max_score, scaled by [member score_curves] if it has any.
func score(context: AIManager) -> float:
	if score_curves.is_empty():
		return max_score
	var amount := 1.0
	for curve in score_curves:
		if curve:
			amount *= curve.amount(context.inputs)
	var low := min_score if min_score > -INF else 0.0
	return low + (max_score - low) * amount


## The conditions it builds from its own settings, such as Attack's reach. Override in a behaviour script; the default: none. Called
## once, the first time they're needed, and again after [method rebuild_conditions].
func own_conditions() -> Array[AICondition]:
	return []


## Its own conditions, then the ones in [member conditions]: everything [method is_available] checks by default.
func all_conditions() -> Array[AICondition]:
	if not _conditions_built:
		_conditions_built = true
		_all_conditions = own_conditions()
		for condition in conditions:
			if condition:
				_all_conditions.append(condition)
	return _all_conditions


## Builds the conditions again at the next decision, after a setting they come from changed (such as a swing's reach).
func rebuild_conditions() -> void:
	_conditions_built = false
	if manager:
		manager.inputs_changed()


## Adds the slots of every input its conditions and curves read to slots (as keys).
func add_input_slots(slots: Dictionary) -> void:
	for condition in all_conditions():
		condition.add_input_slots(slots)
	for curve in score_curves:
		if curve:
			curve.add_input_slots(slots)


## True if its script overrides [method is_available] or [method score] with code of its own. Such a behaviour works everywhere,
## but the C++ decider can't read code, so it asks GDScript for that behaviour's answers. Worked out once per script
## ([ScriptOverrides]).
func has_own_code() -> bool:
	return ScriptOverrides.overrides(get_script(), &"is_available") or ScriptOverrides.overrides(get_script(), &"score")


## Runs tick() at this tick (or the pawn's first run after it), if nothing wakes it sooner. Used up when it fires; an earlier tick
## than one already set wins.
func wake_at(at_tick: int) -> void:
	wake_tick = at_tick if wake_tick < 0 else mini(wake_tick, at_tick)


## Runs tick() when a walk it started ends, arrived or given up (NavigationManager.path_ended).
func wake_on_path_end() -> void:
	wakes_on_path_end = true


## Runs tick() when an ability on this action finishes or is cancelled (AbilityManager.ability_finished, ability_cancelled).
func wake_on_action_end(action: StringName) -> void:
	wakes_on_action = action


## Forgets every wake-up. The manager calls it when the behaviour starts.
func clear_wake_ups() -> void:
	wake_tick = -1
	wakes_on_path_end = false
	wakes_on_action = &""
	woken = false


## Once, when it starts.
func enter(_context: AIManager) -> void:
	pass


## Every tick while it runs. The default runs forever.
func tick(_context: AIManager) -> Status:
	return Status.RUNNING


## Once, when it stops. reason says why, such as "decision", "interrupted", "succeeded", "failed" or "removed".
func exit(_context: AIManager, _reason: String) -> void:
	pass


# --- Used by the manager ---


## True if it's enabled and its tag requirements pass for the pawn's owned tags, given as words ([method OwnedTags.get_words]).
func passes_requirements(owned_words: PackedInt64Array) -> bool:
	return enabled and (tag_requirements == null or tag_requirements.matches_words(owned_words))


## Its own [member tags] as words, parents included, for score modifiers' applies_to.
func tag_words() -> PackedInt64Array:
	if _tag_words_generation != TagRegistry.generation:
		_tag_words_generation = TagRegistry.generation
		_tag_words = TagQuery.words_of(tags)
	return _tag_words


## True while its cooldown hasn't finished.
func is_cooling_down(at_tick: int) -> bool:
	# The parameter is at_tick, not tick: that would clash with tick() above.
	return cooldown_ticks > 0 and ended_tick >= 0 and at_tick - ended_tick < TickDriver.ticks_at_rate(cooldown_ticks)


## This behaviour's jitter amount: its own, or the manager's default when it's -1.
func effective_jitter() -> float:
	if score_jitter >= 0.0:
		return score_jitter
	return manager.default_score_jitter if manager else 0.0


## What persistence adds to its score at this tick.
func persistence_now(at_tick: int) -> float:
	if not _persistence_running or persistence == 0.0 or persistence_fade == null:
		return 0.0
	var along := _persistence_ticks_along(at_tick)
	var amount := persistence * persistence_fade.value_at(along)
	if persistence_mask:
		amount *= persistence_mask.value_at(along)
	return amount


## Its persistence as four numbers: started (1 or 0), ticks along the fade, the tick that was worked out at, and the speed. The
## AIDecisionModule copies them into C++ when the pawn starts deciding there.
func persistence_state() -> PackedFloat64Array:
	return PackedFloat64Array([1.0 if _persistence_running else 0.0, _persistence_along, float(_persistence_changed_tick), _persistence_speed])


## Starts persistence from the beginning of its fade. The manager calls this when the behaviour is chosen.
func start_persistence(at_tick: int) -> void:
	_persistence_running = true
	_persistence_along = 0.0
	_persistence_changed_tick = at_tick
	_persistence_speed = 1.0


## Moves persistence back along its fade by this many ticks, so it lasts longer. Negative: forward, so it ends sooner.
func add_persistence_ticks(ticks: float, at_tick: int) -> void:
	if not _persistence_running:
		return
	_persistence_along = maxf(0.0, _persistence_ticks_along(at_tick) - ticks)
	_persistence_changed_tick = at_tick


## How fast persistence moves along its fade from now on: 1.0 normally, 0.5 for half speed.
func set_persistence_speed(speed: float, at_tick: int) -> void:
	_persistence_along = _persistence_ticks_along(at_tick)
	_persistence_changed_tick = at_tick
	_persistence_speed = maxf(0.0, speed)


# How far along its fade persistence is at this tick.
func _persistence_ticks_along(at_tick: int) -> float:
	return _persistence_along + (at_tick - _persistence_changed_tick) * _persistence_speed
