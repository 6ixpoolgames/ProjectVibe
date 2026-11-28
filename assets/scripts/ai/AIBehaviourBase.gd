# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## The base for one AI behaviour, such as Wander or Chase: one concrete thing to do.
##
## A child of the pawn's [AIBehaviourManager], which only judges between behaviours. Its settings come from its [member definition],
## shared by every pawn using it ([AIBehaviourDefinition]); empty, it runs with its kind's defaults. It acts only by starting steps
## with values ([method start_step]): moving, looking and buttons ([Step], pawn spec 16.7), which write the pawn's input on its own
## [member timeline] each tick the AI controller is asked for input. It never acts on abilities or the body. That one link, a behaviour
## starting steps, is what an order stream carries. Extend it: [method make_default_definition] for settings of its own,
## [method make_steps] for the steps it uses, then [method own_conditions], [method enter], [method tick] (return SUCCEEDED or FAILED
## to finish) and [method exit]. Its node name is its name: the fixed order and the random numbers read it.
## Settings in ticks are written for 60 a second. Design: pawn spec 10.7 and 16.3, scaling spec 6.2.
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
			manager.enabled_changed()
## The settings it runs with: a file shared by every pawn that uses it, or one embedded in this node while prototyping. Empty: its
## kind's defaults. One of another kind falls back to the defaults, with a warning.
@export var definition: AIBehaviourDefinition:
	set(value):
		definition = value
		prepare_settings()

## The settings it runs with: [member definition] worked out, or its kind's defaults, with anything written on the node on top.
## Read-only while playing. Set by [method prepare_settings].
var settings: AIBehaviourDefinition = null
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
## The next tick its [member AIBehaviourDefinition.tick_interval_ticks] brings its tick() round, counted from when it started. Set by
## the manager.
var next_tick_due := -1
## The tick_interval_ticks [member next_tick_due] was worked out for (-1: not yet), so a changed setting counts at once.
var next_tick_interval := -1
## The timing scope names for its is_available() and its tick(), such as &"ai.available.Chase" and &"ai.behaviour.Chase" (see
## [PerfScopes]). Made once by the manager, so timing makes no new names.
var perf_available_name: StringName = &""
## The timing scope name for its tick(), such as &"ai.behaviour.Chase". Made once by the manager.
var perf_tick_name: StringName = &""

## What the behaviour modifiers without a live curve that count for it do to each of its numbers ([enum AIBehaviourModifier.Number]):
## one [code][multiply, add, overrides, override value][/code] per number. Worked out by the manager when they or the owned tags change.
var modifier_changes: Array[PackedFloat64Array] = []
## The modifiers with a live curve that count for it, in the order added, worked out at each read ([method modified]): each
## [code]{number, multiply, add, table, low, high, slot, added, scale}[/code] (slot -1: x is the ticks since added). Set by the manager.
var curved_modifiers: Array[Dictionary] = []
## A blocking behaviour modifier counts for it. Set by the manager with [member modifier_changes].
var decision_blocked := false
## What [method work_out_change] worked out last: the multiply and the add one of its numbers gets.
var change_multiply := 1.0
var change_add := 0.0
## Its script overrides [method score] ([method has_own_score]), noted once by the manager.
var scripted_score := false

# Scratch values for one decision, kept here so a decision creates no arrays or objects. Only the manager reads them.
var decision_jitter := 0.0 # this decision's random offset
var decision_key := 0.0 # its result, known before any of its code runs; INF with a score() of its own (asked when reached)
var decision_available := false # is_available()'s answer this decision, once availability_checked is true
var availability_checked := false
var decision_score := 0.0 # its score before modifiers (settings.base_score, or score()'s answer), once decision_scored is true
var decision_scored := false
var decision_index := 0 # place in the fixed order

## Wake-ups, read by the manager (see the class description). Cleared when it starts.
var wake_tick := -1 # wake_at's tick; -1: none
var wakes_on_step_end := false
var wakes_on_action: StringName = &""
var woken := false # an event it waits for happened since its last tick()

## The timeline its steps run on: its [Step] children and those it makes ([method make_steps]), built the first time it starts. Its
## entries come from [member AIBehaviourDefinition.step_timeline]; with none, code starts every step.
var timeline := StepTimeline.new()
## What its running steps wrote this tick ([method step_input]); the AI controller hands it over.
var steps_input := StepInput.new()

# Works out settings from the definition, the kind's defaults and what's written on the node (shared with abilities).
var _definition_settings := DefinitionSettings.new(self)
var _tag_words := PackedInt64Array()
var _tag_words_generation := -1
var _all_conditions: Array[AICondition] = []
var _conditions_built := false
var _steps_built := false
var _step_by_name := {} # name -> step
var _steps_running := 0
var _moving: MoveStep = null # the move step running now, for its path follower
var _step_results := {} # step name -> how it last ended ("done", "failed", "released", "cancelled")


func _init() -> void:
	set_process(false)
	set_physics_process(false)
	prepare_settings() # its kind's defaults, so it works before a manager collects it (tests call score() directly)


## The definition a new node of this kind runs with: a new definition of the kind's class, with its defaults. Each kind overrides it.
func make_default_definition() -> AIBehaviourDefinition:
	return AIBehaviourDefinition.new()


## Works out [member settings] from [member definition], with settings written on the node on top. Called as it's made, when its
## definition changes, after a setting is written on it, and by the manager as it collects its behaviours. Returns the settings.
func prepare_settings() -> AIBehaviourDefinition:
	settings = _definition_settings.resolve(definition) as AIBehaviourDefinition
	_tag_words_generation = -1
	_conditions_built = false
	_settings_changed()
	return settings


## Gives it another definition while playing. Behaviours can change in play (the AI runs on the server and never rolls back): the
## manager works out its inputs again and C++ gets the new brain.
func use_definition(new_definition: AIBehaviourDefinition) -> void:
	definition = new_definition # works out its settings
	if manager:
		manager.settings_changed()


## Gives it settings of its own, on top of its definition, which this node alone uses: Godot's "Make Unique", while playing. Its
## settings can be written after that. For prototyping and tests; a shipped game uses another definition or a behaviour modifier.
func make_definition_unique() -> AIBehaviourDefinition:
	var own := _definition_settings.make_own(definition) as AIBehaviourDefinition
	use_definition(definition)
	return own


## True if it has settings of its own on top of its definition ([method make_definition_unique], or values a scene sets on the node).
func has_own_settings() -> bool:
	return _definition_settings.own != null


## Where its settings come from, for diagnostics: "fell back", "embedded", "own settings" or "" ([method DefinitionSettings.note]).
func definition_note() -> String:
	return _definition_settings.note(definition)


## Its own yes or no, after the manager's checks: every condition passes ([method all_conditions]). The inputs they read were worked
## out for this decision by the behaviour manager. Overriding this with code works, but see [method has_own_code].
func is_available(context: AIManager) -> bool:
	var inputs := context.inputs
	for condition in all_conditions():
		if not condition.passes(inputs, context, name_hash):
			return false
	return true


## How much it wants to run now, before behaviour modifiers and jitter: [member AIBehaviourDefinition.base_score]. Override it to
## work the score out in code, an open number like the setting. Behaviour modifiers and jitter still apply on top, but neither decider can
## skip a behaviour with its own score() unasked, so it's called whenever it passes the hard rules and its conditions (see
## [method has_own_code]).
func score(_context: AIManager) -> float:
	return settings.base_score


## The conditions it builds from its own settings, such as Attack's reach. Override in a behaviour script; the default: none. Called
## once, the first time they're needed, and again after [method rebuild_conditions].
func own_conditions() -> Array[AICondition]:
	return []


## Its own conditions, then the ones in [member conditions]: everything [method is_available] checks by default.
func all_conditions() -> Array[AICondition]:
	if not _conditions_built:
		_conditions_built = true
		_all_conditions = own_conditions()
		for condition in settings.conditions:
			if condition:
				_all_conditions.append(condition)
	return _all_conditions


## Builds the conditions again at the next decision, after a setting they come from changed (such as a swing's reach).
func rebuild_conditions() -> void:
	_conditions_built = false
	if manager:
		manager.inputs_changed()


## Adds the slots of every input its conditions read to slots (as keys).
func add_input_slots(slots: Dictionary) -> void:
	for condition in all_conditions():
		condition.add_input_slots(slots)


## True if its script overrides [method is_available] or [method score] with code of its own. Such a behaviour works everywhere;
## the C++ decider can't read code, so it asks GDScript for those answers when it reaches the behaviour, as GDScript's decider asks
## them. Keep that code cheap and free of side effects (ai/README.md, "Scripted behaviours under C++"). Worked out once per script
## ([ScriptOverrides]).
func has_own_code() -> bool:
	return has_own_score() or ScriptOverrides.overrides(get_script(), &"is_available")


## True if its script overrides [method score]: its score is known only once asked, so it's asked whenever it passes the rest.
func has_own_score() -> bool:
	return ScriptOverrides.overrides(get_script(), &"score")


## True if the C++ decider can't judge whether it's available from data: it overrides [method is_available], or has a condition of a
## kind C++ doesn't read ([method AICondition.cpp_reads]). C++ then asks GDScript for that behaviour; it judges the rest itself.
func judged_in_gdscript() -> bool:
	if ScriptOverrides.overrides(get_script(), &"is_available"):
		return true
	for condition in all_conditions():
		if not AICondition.cpp_reads(condition.describe()):
			return true
	return false


## Runs tick() at this tick (or the pawn's first run after it), if nothing wakes it sooner. Used up when it fires; an earlier tick
## than one already set wins.
func wake_at(at_tick: int) -> void:
	wake_tick = at_tick if wake_tick < 0 else mini(wake_tick, at_tick)


## Runs tick() when one of its steps ends on its own: done, released or failed (a walk arriving or giving up, a wait running out).
## Not when code stops it.
func wake_on_step_end() -> void:
	wakes_on_step_end = true


## Runs tick() when an ability on this action finishes or is cancelled (AbilityManager.ability_finished, ability_cancelled).
func wake_on_action_end(action: StringName) -> void:
	wakes_on_action = action


## Forgets every wake-up. The manager calls it when the behaviour starts.
func clear_wake_ups() -> void:
	wake_tick = -1
	wakes_on_step_end = false
	wakes_on_action = &""
	woken = false


# --- Steps ---


## The steps it makes for itself if it has no child of that name: each kind overrides it (Chase makes a Follow, a LookAt, a Sprint
## hold and a Dash press). A [Step] child with the same name is used instead, so a scene can swap one ("Sprint" holding another action).
func make_steps() -> Array[Step]:
	return []


## The action its steps' conditions mean by "its action" ([member StepCondition.action] empty): [member AIBehaviourDefinition.presses_action].
func default_action() -> StringName:
	return settings.presses_action if settings else &""


## The input its steps write ([member steps_input]): how an [InputStep] finds it when the timeline is built.
func step_input() -> StepInput:
	return steps_input


## One of its steps by name, or null. Builds its timeline if it hasn't been yet.
func get_step(step_name: StringName) -> Step:
	_build_steps()
	return _step_by_name.get(step_name)


## Starts one of its steps with these values (property names to values, written onto the step first). A step already running is
## stopped ("cancelled") and started again with them. Returns the step, or null if it has none by that name. The order stream's hook,
## [member AIBehaviourManager.order_listener], hears it.
func start_step(step_name: StringName, values := {}) -> Step:
	var step := get_step(step_name)
	if step == null:
		push_warning("%s: it has no step called '%s'." % [name, step_name])
		return null
	if step.running:
		timeline.stop_step(step, "cancelled")
	for key in values:
		step.set(key, values[key])
	timeline.start_step(step)
	if AIBehaviourManager.order_listener.is_valid() and manager:
		AIBehaviourManager.order_listener.call(manager, &"step_started", [name, step_name, values])
	return step


## Stops one of its steps if it runs, with this reason. The order stream's hook hears it.
func stop_step(step_name: StringName, reason := "cancelled") -> void:
	var step := get_step(step_name)
	if step == null or not step.running:
		return
	timeline.stop_step(step, reason)
	if AIBehaviourManager.order_listener.is_valid() and manager:
		AIBehaviourManager.order_listener.call(manager, &"step_stopped", [name, step_name, reason])


## True while the step with this name runs.
func is_step_running(step_name: StringName) -> bool:
	var step := get_step(step_name)
	return step != null and step.running


## How the step with this name last ended: "done", "released", "failed" or "cancelled"; "" if it hasn't ended since the behaviour
## started.
func step_result(step_name: StringName) -> String:
	return _step_results.get(step_name, "")


## The path follower of the move step running now, or null: what the AI controller walks the pawn along.
func moving_follower() -> PathFollower:
	return _moving.follower if _moving and _moving.follower.is_under_way() else null


## True while any of its steps runs.
func has_running_steps() -> bool:
	return _steps_running > 0


## The manager calls this as it starts, before [method enter]: begins a run of its timeline (entries due at once start).
func begin_steps(tick: int) -> void:
	_build_steps()
	_step_results.clear()
	steps_input.clear()
	if timeline.has_steps():
		timeline.begin(tick)


## The manager calls this after [method exit]: every step still running stops ("cancelled").
func end_steps() -> void:
	if _steps_running > 0:
		timeline.end("cancelled")
	_steps_running = 0
	_moving = null
	steps_input.clear()


## The AI controller calls this once per tick it's asked for input, while this behaviour runs: clears [member steps_input] and lets
## the running steps write it, covering elapsed ticks.
func run_steps(elapsed: int) -> void:
	steps_input.clear()
	if _steps_running > 0:
		timeline.run(TickDriver.get_tick_dt() * elapsed, elapsed)


func _build_steps() -> void:
	if _steps_built:
		return
	_steps_built = true
	var steps: Array[Step] = []
	for child in get_children():
		if child is Step:
			steps.append(child)
			_step_by_name[child.name] = child
	for made in make_steps():
		if _step_by_name.has(made.name):
			made.free() # a child of that name is used instead
			continue
		add_child(made, false, Node.INTERNAL_MODE_BACK) # made by code: not saved with the scene
		steps.append(made)
		_step_by_name[made.name] = made
	for step in steps:
		step.pawn = pawn
	timeline.host = self
	timeline.owner_name = "%s's behaviour %s" % [pawn.name if pawn else "?", name]
	var entries: Array[TimelineEntry] = []
	if settings:
		entries.assign(settings.step_timeline)
	if entries.is_empty():
		for step in steps:
			var entry := TimelineEntry.new() # manual: started from code only
			entry.step = step.name
			entry.manual = true
			entries.append(entry)
	timeline.build(steps, entries)


## The name of the Hold step behaviours that sprint use ([method made_sprint_step]).
const SPRINT_STEP := &"Sprint"
## The action that step holds by default. A game whose sprint is another action gives the behaviour a [HoldStep] child named "Sprint"
## holding it, which is used instead.
const SPRINT_ACTION := &"sprint"


## The Sprint step: a [HoldStep] of [constant SPRINT_ACTION], named [constant SPRINT_STEP].
static func made_sprint_step() -> Step:
	return made_step(HoldStep, SPRINT_STEP, {"action": SPRINT_ACTION})


## A step of this kind with this name and settings: for [method make_steps].
static func made_step(kind: Script, step_name: StringName, values := {}) -> Step:
	var step: Step = kind.new()
	step.name = step_name
	for key in values:
		step.set(key, values[key])
	return step


# What its timeline tells it (StepTimeline's host methods). The AI never rolls back, so state changes need no pushing.
func _timeline_state_written() -> void:
	pass


func _timeline_step_started(step: Step) -> void:
	_steps_running += 1
	if step is MoveStep:
		_moving = step


func _timeline_step_finished(step: Step, reason: String) -> void:
	_steps_running = maxi(_steps_running - 1, 0)
	_step_results[step.name] = reason
	if step == _moving:
		_moving = null
	if wakes_on_step_end and reason != "cancelled":
		woken = true


func _timeline_runaway() -> void:
	timeline.end("cancelled")


## Once, when it starts.
func enter(_context: AIManager) -> void:
	pass


## Every tick while it runs. The default runs forever.
func tick(_context: AIManager) -> Status:
	return Status.RUNNING


## Once, when it stops. reason says why, such as "decision", "interrupted", "succeeded", "failed" or "removed".
func exit(_context: AIManager, _reason: String) -> void:
	pass


# Each kind's typed reference to its settings is set here (AIChaseBehaviour._kind_settings).
func _settings_changed() -> void:
	pass


# Settings by name on the node (pawn spec 16.3): any setting of its definition's class, such as behaviour.base_score, reads from its
# settings and writes into its own variant, for code outside the behaviour and values a scene sets. Code inside a behaviour reads
# settings.<name> (or its kind's typed reference). A write is free before the manager sets it up, and after that only once it has its
# own variant (make_definition_unique).
func _get(property: StringName) -> Variant:
	if not _definition_settings.has_setting(property):
		return null
	return settings.get(property)


func _set(property: StringName, value: Variant) -> bool:
	if not _definition_settings.has_setting(property):
		return false
	if _definition_settings.write(definition, property, value, manager != null):
		prepare_settings()
		if manager:
			manager.settings_changed()
	return true


func _describe_node() -> String:
	return "%s/%s" % [pawn.name, name] if pawn else String(name)


# --- Used by the manager ---


## True if it's enabled and its tag requirements pass for the pawn's owned tags, given as words ([method OwnedTags.get_words]).
func passes_requirements(owned_words: PackedInt64Array) -> bool:
	return enabled and (settings.tag_requirements == null or settings.tag_requirements.matches_words(owned_words))


## Its own [member tags] as words, parents included, for score modifiers' applies_to.
func tag_words() -> PackedInt64Array:
	if _tag_words_generation != TagRegistry.generation:
		_tag_words_generation = TagRegistry.generation
		_tag_words = TagQuery.words_of(settings.tags)
	return _tag_words


## True while its cooldown (as its modifiers leave it) hasn't finished.
func is_cooling_down(at_tick: int) -> bool:
	# The parameter is at_tick, not tick: that would clash with tick() above.
	var cooldown := current_cooldown_ticks()
	return cooldown > 0 and ended_tick >= 0 and at_tick - ended_tick < cooldown


## This behaviour's jitter amount before modifiers: its own, or the manager's default when it's -1.
func effective_jitter() -> float:
	if settings.score_jitter >= 0.0:
		return settings.score_jitter
	return manager.default_score_jitter if manager else 0.0


## One of its numbers as its modifiers leave it now: base times their multiplies plus their adds, or the last override. A modifier with
## a live curve is worked out at the manager's tick and this decision's inputs. Twin of the C++ decider's: the same arithmetic.
func modified(number: AIBehaviourModifier.Number, base: float) -> float:
	if modifier_changes.is_empty() and curved_modifiers.is_empty():
		return base
	work_out_change(number)
	return base * change_multiply + change_add


## Works out [member change_multiply] and [member change_add] for one of its numbers now: what [method modified] applies (an override
## is a multiply of 0 and an add of its value). For decision records; 1 and 0 with no modifiers.
func work_out_change(number: AIBehaviourModifier.Number) -> void:
	change_multiply = 1.0
	change_add = 0.0
	if not modifier_changes.is_empty():
		var change := modifier_changes[number]
		if change[2] != 0.0:
			change_multiply = 0.0 # an override: curves don't change it
			change_add = change[3]
			return
		change_multiply = change[0]
		change_add = change[1]
	for entry in curved_modifiers:
		if entry["number"] != number:
			continue
		var strength := curve_strength(entry)
		change_multiply *= AIBehaviourModifier.multiply_at(entry["multiply"], strength)
		change_add += float(entry["add"]) * strength


## A live curve's strength now: x is the ticks since its modifier was added, or its input, either times its scale (an input in ticks,
## and time, at 60 a second).
func curve_strength(entry: Dictionary) -> float:
	var slot: int = entry["slot"]
	var raw := float(manager.modifier_tick - int(entry["added"])) if slot < 0 else pawn.ai.inputs.value(slot)
	return AIBehaviourModifier.strength_in(entry["table"], entry["low"], entry["high"], raw * float(entry["scale"]))


## Its score with modifiers, from a base: its settings' score, or what its own score() gave.
func current_score(base: float) -> float:
	return modified(AIBehaviourModifier.Number.SCORE, base)


## Its jitter amount with modifiers, never below 0.
func current_jitter() -> float:
	return maxf(0.0, modified(AIBehaviourModifier.Number.SCORE_JITTER, effective_jitter()))


## Its interrupt threshold with modifiers.
func current_interrupt_threshold() -> int:
	return roundi(modified(AIBehaviourModifier.Number.INTERRUPT_THRESHOLD, settings.interrupt_threshold))


## Its cooldown with modifiers, in this match's ticks; 0: none.
func current_cooldown_ticks() -> int:
	return TickDriver.ticks_at_rate(maxi(0, roundi(modified(AIBehaviourModifier.Number.COOLDOWN_TICKS, settings.cooldown_ticks))))


## Its minimum run with modifiers, in this match's ticks; 0: none.
func current_min_run_ticks() -> int:
	return TickDriver.ticks_at_rate(maxi(0, roundi(modified(AIBehaviourModifier.Number.MIN_RUN_TICKS, settings.min_run_ticks))))
