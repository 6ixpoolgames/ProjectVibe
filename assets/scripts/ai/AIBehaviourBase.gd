# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## The base for one AI behaviour, such as Wander or Chase: one concrete thing to do.
##
## A child of the pawn's [AIBehaviourManager], which only judges between behaviours. Its settings come from its [member definition],
## shared by every pawn using it ([AIBehaviourDefinition]); empty, it runs with its kind's defaults. It acts only through the AI
## controller ([code]context.controller.move_to()[/code], [code]press()[/code]), never on abilities or the body. Extend it:
## [method make_default_definition] for settings of its own, then [method own_conditions], [method enter], [method tick] (return
## SUCCEEDED or FAILED to finish) and [method exit]. Its node name is its name: the fixed order and the random numbers read it.
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
			manager.inputs_changed() # C++ gets the brain again
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
## The timing scope names for its is_available() and its tick(), such as &"ai.available.Chase" and &"ai.behaviour.Chase" (see
## [PerfScopes]). Made once by the manager, so timing makes no new names.
var perf_available_name: StringName = &""
## The timing scope name for its tick(), such as &"ai.behaviour.Chase". Made once by the manager.
var perf_tick_name: StringName = &""

## What the behaviour modifiers that count for it do to each of its numbers ([enum AIBehaviourModifier.Number]): one
## [code][multiply, add, overrides, override value][/code] per number. Worked out by the manager when they or the owned tags change.
var modifier_changes: Array[PackedFloat64Array] = []
## A blocking behaviour modifier counts for it. Set by the manager with [member modifier_changes].
var decision_blocked := false

# Scratch values for one decision, kept here so a decision creates no arrays or objects. Only the manager reads them.
var decision_bonus := 0.0 # score_bonus() for this decision
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

# Works out settings from the definition, the kind's defaults and what's written on the node (shared with abilities).
var _definition_settings := DefinitionSettings.new(self)
var _tag_words := PackedInt64Array()
var _tag_words_generation := -1
var _all_conditions: Array[AICondition] = []
var _conditions_built := false


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


## How much it wants to run now, between min_score and max_score: max_score, scaled by [member score_curves] if it has any.
func score(context: AIManager) -> float:
	if settings.score_curves.is_empty():
		return settings.max_score
	var amount := 1.0
	for curve in settings.score_curves:
		if curve:
			amount *= curve.amount(context.inputs)
	var low := settings.min_score if settings.min_score > -INF else 0.0
	return low + (settings.max_score - low) * amount


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


## Adds the slots of every input its conditions and curves read to slots (as keys).
func add_input_slots(slots: Dictionary) -> void:
	for condition in all_conditions():
		condition.add_input_slots(slots)
	for curve in settings.score_curves:
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


## Runs tick() when a walk it started ends, arrived or given up (PathFollower.path_ended, on the AI controller's follower).
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


# Each kind's typed reference to its settings is set here (AIChaseBehaviour._kind_settings).
func _settings_changed() -> void:
	pass


# Settings by name on the node (pawn spec 16.3): any setting of its definition's class, such as behaviour.max_score, reads from its
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


## One of its numbers as its modifiers leave it: base times their multiplies plus their adds, or the last override.
func modified(number: AIBehaviourModifier.Number, base: float) -> float:
	if modifier_changes.is_empty():
		return base
	var change := modifier_changes[number]
	return change[3] if change[2] != 0.0 else base * change[0] + change[1]


## What its modifiers add to its score (0 with none).
func score_bonus() -> float:
	return modified(AIBehaviourModifier.Number.SCORE_BONUS, 0.0)


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
