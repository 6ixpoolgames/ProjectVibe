# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## One thing a pawn can do, such as walk, jump, swing or dash: a child of the pawn's [AbilityManager].
##
## Its settings come from its [member definition], a Resource every pawn using it shares (ability spec 3): the node holds that
## reference and its state, and reads each setting from the definition. Empty, it runs with its kind's defaults.
## [br][br]Extend it, override [method make_default_definition] for a kind with settings of its own, and override [method can_start],
## [method start], [method tick], [method stop] and, for counters that run all the time, [method every_tick] (with [method can_sleep]).
## A quick ability can instead set base settings in [code]_init()[/code]: they go into a definition of its own. LOCOMOTION abilities move the pawn every tick
## they're chosen (one runs at a time); ACTION abilities start on a press of their [member trigger_action], at once or for a
## [member duration_ticks]. Players' keys and AI behaviours press the same actions. Times are set in ticks at 60 a second and converted
## to the match's rate.
## [br][br]Rollback: whatever an ability keeps between ticks must be named in [method get_pushed_properties] (its setter calls
## [method push_state]) or [method get_rollback_properties] (read at every commit); the base already covers its own timers and step
## state. It can also be built from [AbilityStep] children (a windup, a turn, a swing) and carry [HitInterceptor] children that stop
## hits while it runs.
## Design: pawn spec 8, 8.20, 8.23.
class_name AbilityBase
extends Node

enum Kind { LOCOMOTION, ACTION }

## Sent on the server for each pawn this ability hits, by a swing or by its projectile, as the hit is made ([method HitInfo.deliver]).
## The target takes it later in the same tick, after every pawn has simulated (pawn spec 15.4).
@warning_ignore("unused_signal") # sent by HitInfo.deliver
signal hit_landed(hit: HitInfo)
## Sent once per sweep, on its first tick, with where the hit sphere is and its radius. Every machine that runs the swing sends it
## (server, offline, a predicting client), never during a replay. Says where it can hit, not whether it did: see [signal hit_landed].
@warning_ignore("unused_signal") # sent by MeleeSweepStep
signal hit_window_started(centre: Vector3, radius: float)
## Sent every tick of a sweep, on the same machines as [signal hit_window_started], with the hit sphere's start and end for this tick.
@warning_ignore("unused_signal") # sent by MeleeSweepStep
signal hit_area_moved(from: Vector3, to: Vector3, radius: float)
## Its swing met something, where hits are decided: one entry of its [member hit_run]'s log (see [method HitRun.entry]), hit or not.
@warning_ignore("unused_signal") # sent through its HitRun
signal intersected(entry: Dictionary)

## What the code does with it: move the pawn every tick, or start on a press. Set by the kind's script.
@export var kind := Kind.ACTION
## The settings it runs with (ability spec 3): a file shared by every pawn that uses it, or one embedded in this node while
## prototyping. Empty: its kind's defaults. One of another kind falls back to the defaults, with a warning.
@export var definition: AbilityDefinition
## The settings it runs with: [member definition] worked out ([method AbilityDefinition.resolved]), or its kind's defaults. Read-only
## while playing. Set by [method prepare_settings].
var settings: AbilityDefinition = null
## True if its definition was of another kind, so it runs with its kind's defaults (diagnostics lists these).
var definition_fell_back := false
# Its own settings on top of its definition (a variant based on it), made when a setting is written on the node.
var _own_definition: AbilityDefinition = null
# Each kind's defaults, made once and shared by every node of that kind: script -> definition.
static var _kind_defaults := {}
## From the definition: [member AbilityDefinition.trigger_action].
var trigger_action: StringName:
	get:
		if settings == null:
			prepare_settings()
		return settings.trigger_action
	set(value):
		_write_setting(&"trigger_action", value)
## From the definition: [member AbilityDefinition.category].
var category: StringName:
	get:
		if settings == null:
			prepare_settings()
		return settings.category
	set(value):
		_write_setting(&"category", value)
## From the definition: [member AbilityDefinition.extra_categories].
var extra_categories: Array[StringName]:
	get:
		if settings == null:
			prepare_settings()
		return settings.extra_categories
	set(value):
		_write_setting(&"extra_categories", value)
## From the definition: [member AbilityDefinition.max_charges].
var max_charges: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.max_charges
	set(value):
		_write_setting(&"max_charges", value)
## From the definition: [member AbilityDefinition.recharges].
var recharges: bool:
	get:
		if settings == null:
			prepare_settings()
		return settings.recharges
	set(value):
		_write_setting(&"recharges", value)
## From the definition: [member AbilityDefinition.charge_restore_ticks].
var charge_restore_ticks: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.charge_restore_ticks
	set(value):
		_write_setting(&"charge_restore_ticks", value)
## From the definition: [member AbilityDefinition.charges_restored].
var charges_restored: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.charges_restored
	set(value):
		_write_setting(&"charges_restored", value)
## From the definition: [member AbilityDefinition.restore_all_charges].
var restore_all_charges: bool:
	get:
		if settings == null:
			prepare_settings()
		return settings.restore_all_charges
	set(value):
		_write_setting(&"restore_all_charges", value)
## From the definition: [member AbilityDefinition.has_charges_tag].
var has_charges_tag: StringName:
	get:
		if settings == null:
			prepare_settings()
		return settings.has_charges_tag
	set(value):
		_write_setting(&"has_charges_tag", value)
## From the definition: [member AbilityDefinition.start_requirements].
var start_requirements: TagQuery:
	get:
		if settings == null:
			prepare_settings()
		return settings.start_requirements
	set(value):
		_write_setting(&"start_requirements", value)
## From the definition: [member AbilityDefinition.priority].
var priority: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.priority
	set(value):
		_write_setting(&"priority", value)
## From the definition: [member AbilityDefinition.combo_positions].
var combo_positions: Array[int]:
	get:
		if settings == null:
			prepare_settings()
		return settings.combo_positions
	set(value):
		_write_setting(&"combo_positions", value)
## From the definition: [member AbilityDefinition.priority_jitter].
var priority_jitter: float:
	get:
		if settings == null:
			prepare_settings()
		return settings.priority_jitter
	set(value):
		_write_setting(&"priority_jitter", value)
## From the definition: [member AbilityDefinition.duration_ticks].
var duration_ticks: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.duration_ticks
	set(value):
		_write_setting(&"duration_ticks", value)
## From the definition: [member AbilityDefinition.cooldown_ticks].
var cooldown_ticks: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.cooldown_ticks
	set(value):
		_write_setting(&"cooldown_ticks", value)
## From the definition: [member AbilityDefinition.locks_out].
var locks_out: Array[StringName]:
	get:
		if settings == null:
			prepare_settings()
		return settings.locks_out
	set(value):
		_write_setting(&"locks_out", value)
## From the definition: [member AbilityDefinition.buffer_window_ticks].
var buffer_window_ticks: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.buffer_window_ticks
	set(value):
		_write_setting(&"buffer_window_ticks", value)
## From the definition: [member AbilityDefinition.interrupt_priority].
var interrupt_priority: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.interrupt_priority
	set(value):
		_write_setting(&"interrupt_priority", value)
## From the definition: [member AbilityDefinition.interrupt_threshold].
var interrupt_threshold: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.interrupt_threshold
	set(value):
		_write_setting(&"interrupt_threshold", value)
## From the definition: [member AbilityDefinition.cancelled_by].
var cancelled_by: Array[StringName]:
	get:
		if settings == null:
			prepare_settings()
		return settings.cancelled_by
	set(value):
		_write_setting(&"cancelled_by", value)
## From the definition: [member AbilityDefinition.pauses_locomotion].
var pauses_locomotion: bool:
	get:
		if settings == null:
			prepare_settings()
		return settings.pauses_locomotion
	set(value):
		_write_setting(&"pauses_locomotion", value)
## From the definition: [member AbilityDefinition.needs_full_movement].
var needs_full_movement: bool:
	get:
		if settings == null:
			prepare_settings()
		return settings.needs_full_movement
	set(value):
		_write_setting(&"needs_full_movement", value)
## From the definition: [member AbilityDefinition.step_timeline].
var step_timeline: Array[TimelineEntry]:
	get:
		if settings == null:
			prepare_settings()
		return settings.step_timeline
	set(value):
		_write_setting(&"step_timeline", value)
## From the definition: [member AbilityDefinition.max_steps_ticks].
var max_steps_ticks: int:
	get:
		if settings == null:
			prepare_settings()
		return settings.max_steps_ticks
	set(value):
		_write_setting(&"max_steps_ticks", value)

# State that rolls back, pushed to the state store when it changes (push_state). Timers are tick deadlines, which don't change while
# they run (ability spec 4): nothing counts down, and a pawn running every Nth tick needs nothing special. Each setter tells the manager,
# which keeps the soonest deadline (pawn spec 15.2); a rollback loading values goes through them too.
## The tick the current (or last) timed run started.
var started_at := -1:
	set(value):
		if value == started_at:
			return
		started_at = value
		push_state(&"started_at", value)
## The tick the current timed run ends: the manager finishes it on its first run at or after this tick. -1: not running.
var ends_at := -1:
	set(value):
		if value == ends_at:
			return
		var flips := (value >= 0) != (ends_at >= 0)
		ends_at = value
		push_state(&"ends_at", value)
		if manager and flips:
			manager.timers_changed()
		if flips:
			_set_owned_tags(value >= 0)
			_running_changed(value >= 0)
## The tick it can start again: ready from this tick on.
var ready_at := 0:
	set(value):
		if value == ready_at:
			return
		ready_at = value
		push_state(&"ready_at", value)
		if manager:
			manager.timers_changed()
## Charges used and not yet back (its definition's max_charges above 0). A start spends one.
var charges_spent := 0:
	set(value):
		if value == charges_spent:
			return
		charges_spent = value
		push_state(&"charges_spent", value)
		_charges_changed()
## The tick spent charges next come back (a deadline); -1: none waiting.
var next_restore_tick := -1:
	set(value):
		if value == next_restore_tick:
			return
		next_restore_tick = value
		push_state(&"next_restore_tick", value)
		if manager:
			manager.timers_changed()
## Its most charges before changes that last a while: -1 for its definition's max_charges, or what [method set_max_charges] set for good.
var max_charges_base := -1:
	set(value):
		if value == max_charges_base:
			return
		max_charges_base = value
		push_state(&"max_charges_base", value)
		_charges_changed()
## Changes to its most charges that last a while, by name: {name: [amount, the tick it ends or -1]}. Change it with
## [method add_max_charges_change] and [method remove_max_charges_change]; a new Dictionary each time, so it's pushed.
var max_charges_changes := {}:
	set(value):
		max_charges_changes = value
		push_state(&"max_charges_changes", value)
		_charges_changed()
		if manager:
			manager.timers_changed() # an end is a deadline
## A press waiting in the buffer waits until this tick (not including it).
var buffer_until := 0:
	set(value):
		if value == buffer_until:
			return
		buffer_until = value
		push_state(&"buffer_until", value)
		if manager:
			manager.timers_changed()

## Set by the AbilityManager.
var manager: AbilityManager = null
## Set by the AbilityManager: a number from its name, for the priority_jitter offset.
var jitter_salt := 0
var pawn: Pawn = null
## Its category and extra_categories as bits, with their parents'. Worked out once by the manager.
var category_mask := 0
## locks_out as bits. Worked out once by the manager.
var locks_out_mask := 0
## cancelled_by as bits. Worked out once by the manager, so the check while playing is one bit test.
var cancelled_by_mask := 0
## trigger_action's input bit ([InputActions]), or 0 with none. Worked out once by the manager (pawn spec 15.2).
var trigger_bit := 0
## Effects on its own pawn when it starts, from its EffectApplier children, collected once by the manager (pawn spec 8.11).
var on_start_effects: Array[Effect] = []
## Effects on a pawn it hits, handed to the [HitInfo] by [method land_hit] (a sweep's hit or a projectile's).
var on_hit_effects: Array[Effect] = []
## Effects on its own pawn when it hits, handed over by [method land_hit] like [member on_hit_effects].
var on_hit_self_effects: Array[Effect] = []
## Its [HitInterceptor]s, under it or its steps, found by the manager (pawn spec 8.23).
var interceptors: Array[HitInterceptor] = []
## Its [AbilityStep] children in tree order, found by [method collect_steps]. Empty: no steps.
var steps: Array[AbilityStep] = []
## The step timeline it runs (ability spec 6.2): its definition's [member AbilityDefinition.step_timeline], else its kind's default
## ([method default_timeline]), else its steps one after another in tree order; plus a manual entry for each step none names. Worked
## out by [method collect_steps].
var timeline: Array[TimelineEntry] = []
## Its timeline's state, four numbers per entry: the tick it started, the tick it ended (-1: not yet), why it ended
## ([enum TimelineEntry.Reason], 0 none) and where its step's count starts (the start, moved on by ticks that didn't count). Rolled
## back as one value. A step that only waits out its length changes nothing while it runs.
var timeline_state := PackedInt32Array():
	set(value):
		if value == timeline_state:
			return
		timeline_state = value
		push_state(&"timeline_state", value)
## [member ends_at] for a run with no end of its own yet (Death, while Health is 0).
const NEVER := 1 << 62
## The most steps one ability may start in one tick, a guard against steps that start and stop each other in a loop. Past it, starts
## are refused, the ability ends and it warns once.
const MAX_STEP_STARTS_PER_TICK := 32
var _starts_tick := -1 # the tick _starts_this_tick counts for
## The pawns it has hit this run, by entity id (instance id for a pawn not spawned through the session), so each is hit once across
## all its sweeps (ability spec 8). Rolls back (pushed). At most [constant MAX_HITS_PER_RUN]; cleared when it starts.
var pawns_hit_this_run := PackedInt64Array():
	set(value):
		if value == pawns_hit_this_run:
			return
		pawns_hit_this_run = value
		push_state(&"pawns_hit_this_run", value)
## The most pawns one run can hit. Past it a swing hits no one new, with a warning once: a fixed size keeps the rolled-back list small.
const MAX_HITS_PER_RUN := 32
var _warned_hit_cap := false
## Its swing's hit run ([method get_hit_run]); null until first used.
var hit_run: HitRun = null
var _hit_swap: HitDefinition = null # a hit definition swapped in while playing (use_hit_definition)
var _warned_no_effects := false
static var _shared_default_hit: HitDefinition = null
var _starts_this_tick := 0
var _warned_too_many_starts := false
# Where push_state sends values: the pawn's TickStateComponent, and each pushed property's entry there ("AbilityManager/Swing:ends_at").
# Set by the manager when it registers them.
var _tick_state: TickStateComponent = null
var _pushed_keys := {}


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## The definition a new node of this kind runs with: a new definition of the kind's class, with its defaults. Each kind overrides it.
func make_default_definition() -> AbilityDefinition:
	return AbilityDefinition.new()


## This kind's defaults, shared by every node of the kind.
func kind_defaults() -> AbilityDefinition:
	var script: Script = get_script()
	var found: AbilityDefinition = _kind_defaults.get(script)
	if found == null:
		found = make_default_definition()
		_kind_defaults[script] = found
	return found


## Works out [member settings] from [member definition]: its kind's defaults with none, or with one of another kind (warning). Settings
## written on the node (a script's _init(), old scene values, [method make_definition_unique]) go into a variant of its own on top.
## The manager calls it as it collects its abilities; reading a setting before then calls it too. Returns the settings.
func prepare_settings() -> AbilityDefinition:
	var defaults := kind_defaults()
	var base: AbilityDefinition = definition
	definition_fell_back = false
	if base and not _definition_fits(base, defaults):
		push_warning("[AbilityBase] %s: its definition %s is for another kind of ability; it runs with the %s defaults." % [_describe_node(), base.describe(), defaults.get_script().get_global_name()])
		definition_fell_back = true
		base = null
	var chosen: AbilityDefinition = base if base else defaults
	if _own_definition:
		_own_definition.based_on = chosen # its own changes on top of the definition, or of the kind's defaults
		chosen = _own_definition
	settings = chosen.resolved() as AbilityDefinition
	_settings_changed()
	return settings


## Gives it another definition while playing (a weapon swap), and has the manager work out its masks and lists again. What rolls back
## was decided when the pawn started, so a definition that turns on a timer this ability didn't have won't roll it back.
func use_definition(new_definition: AbilityDefinition) -> void:
	definition = new_definition
	prepare_settings()
	if manager:
		manager.settings_changed()


## Gives it settings of its own, on top of its definition, which this node alone uses: Godot's "Make Unique", while playing. Its
## settings can be written after that. For prototyping and tests; a shipped game uses another definition.
func make_definition_unique() -> AbilityDefinition:
	if _own_definition == null:
		_own_definition = _new_own_definition()
	use_definition(definition)
	return _own_definition


## True if it has settings of its own on top of its definition ([method make_definition_unique], its script's _init(), or values a
## scene sets on the node), not only the shared ones.
func has_own_settings() -> bool:
	return _own_definition != null


## What to check about where its settings come from, for diagnostics: "fell back" (a definition of another kind), "embedded" (saved
## in a scene, a prototype tweak), "own settings" (written on the node), or "" when it runs with a definition file or its kind's defaults.
func definition_note() -> String:
	if definition_fell_back:
		return "fell back"
	if definition and definition.is_embedded():
		return "embedded"
	if has_own_settings():
		return "own settings"
	return ""


# Its own variant, of the definition's class, based on the definition (or the kind's defaults) from the start, so what's written on it
# counts as changed.
func _new_own_definition() -> AbilityDefinition:
	var base: AbilityDefinition = definition if definition and _definition_fits(definition, kind_defaults()) else kind_defaults()
	var own: AbilityDefinition = base.get_script().new()
	own.based_on = base
	return own


# Each kind's typed reference to its settings is set here (MeleeAttackAbility._melee).
func _settings_changed() -> void:
	pass


# A setting written on the node goes into its own variant: freely before the manager sets it up (its script's _init(), values a scene
# sets), and after that only once it has one (make_definition_unique). Otherwise it's an error: the definition is shared.
func _write_setting(setting: StringName, value: Variant) -> void:
	if _own_definition == null:
		if manager:
			push_error("[AbilityBase] %s: %s comes from its definition, which every pawn using it shares; give it another with use_definition(), or its own copy with make_definition_unique()." % [_describe_node(), setting])
			return
		_own_definition = _new_own_definition()
	_own_definition.set(setting, value)
	if settings != null:
		prepare_settings()


# True if the definition is of this kind's class, or a class built on it.
func _definition_fits(chosen: AbilityDefinition, defaults: AbilityDefinition) -> bool:
	var script: Script = chosen.get_script()
	var wanted: Script = defaults.get_script()
	while script:
		if script == wanted:
			return true
		script = script.get_base_script()
	return false


func _describe_node() -> String:
	return "%s/%s" % [pawn.name, name] if pawn else String(name)


## The properties on this node that roll back and whose setters call [method push_state], so the state store records them only when
## they change (state store spec 6.3). An ability that keeps more adds to it with [code]super()[/code]. The cheap way, and the one the
## built-in abilities use.
func get_pushed_properties() -> Array[String]:
	var out: Array[String] = []
	if is_timed():
		out.append_array(["started_at", "ends_at"])
	if is_stepped():
		out.append("timeline_state") # every timeline entry's state, as one value
		out.append("pawns_hit_this_run")
	if cooldown_ticks > 0:
		out.append("ready_at")
	if buffer_window_ticks > 0 and trigger_action != &"":
		out.append("buffer_until")
	if uses_charges():
		out.append_array(["charges_spent", "next_restore_tick", "max_charges_base", "max_charges_changes"])
	return out


## Other properties on this node that roll back, read from the node at every commit: no setter needed, so the easy way for a quick
## ability, but each costs a read per pawn per tick. None in the base.
func get_rollback_properties() -> Array[String]:
	return []


## True if it has limited uses (its definition's max_charges above 0).
func uses_charges() -> bool:
	return max_charges > 0


## Its most charges now: its own value (the definition's, or what [method set_max_charges] set) plus the changes still running. Never
## below 0.
func max_charges_now(at_tick := -1) -> int:
	var now := TickDriver.tick if at_tick < 0 else at_tick
	var most := max_charges_base if max_charges_base >= 0 else max_charges
	for change: Array in max_charges_changes.values():
		if change[1] < 0 or now < change[1]:
			most += int(change[0])
	return maxi(most, 0)


## Charges left now; -1 with no limit.
func charges_left() -> int:
	return maxi(max_charges_now() - charges_spent, 0) if uses_charges() else -1


## Changes its most charges for good (a bigger quiver). Rolled back.
func set_max_charges(value: int) -> void:
	max_charges_base = maxi(value, 0)


## Changes its most charges by amount for lasting_ticks (at 60 a second; 0: until removed), under a name; the same name replaces the
## last. Rolled back, so a name, not an object: the same on every machine.
func add_max_charges_change(change_name: StringName, amount: int, lasting_ticks := 0) -> void:
	var changes := max_charges_changes.duplicate()
	var ends := TickDriver.tick + TickDriver.ticks_at_rate(lasting_ticks) if lasting_ticks > 0 else -1
	changes[String(change_name)] = [amount, ends]
	max_charges_changes = changes


## Takes a change to its most charges away.
func remove_max_charges_change(change_name: StringName) -> void:
	if max_charges_changes.has(String(change_name)):
		var changes := max_charges_changes.duplicate()
		changes.erase(String(change_name))
		max_charges_changes = changes


## Every charge back at once (a revive, a reload).
func refill_charges() -> void:
	charges_spent = 0
	next_restore_tick = -1


## The manager calls this when it starts: one charge spent, and the restore clock started if none was waiting.
func spend_charge() -> void:
	if not uses_charges():
		return
	charges_spent += 1
	if next_restore_tick < 0 and recharges:
		next_restore_tick = TickDriver.tick + TickDriver.ticks_at_rate(charge_restore_ticks)


## The manager calls this when a charge deadline passes: charges come back for every restore due by now, each counted from the last,
## and changes that ended are dropped.
func apply_charge_deadlines(now: int) -> void:
	while next_restore_tick >= 0 and now >= next_restore_tick:
		var back := charges_spent if restore_all_charges else charges_restored
		charges_spent = maxi(charges_spent - back, 0)
		next_restore_tick = next_restore_tick + TickDriver.ticks_at_rate(charge_restore_ticks) if charges_spent > 0 and recharges else -1
	var ended := false
	for change: Array in max_charges_changes.values():
		ended = ended or (change[1] >= 0 and now >= change[1])
	if ended:
		var kept := {}
		for key: String in max_charges_changes:
			var change: Array = max_charges_changes[key]
			if change[1] < 0 or now < change[1]:
				kept[key] = change
		max_charges_changes = kept


## The soonest charge deadline still ahead (a restore, or a change to the most ending); -1: none.
func next_charge_deadline() -> int:
	var soonest := next_restore_tick
	for change: Array in max_charges_changes.values():
		if change[1] >= 0 and (soonest < 0 or change[1] < soonest):
			soonest = change[1]
	return soonest


## Its has_charges_tag owned or not, as its charges say now. The manager calls it as it collects abilities and after a rollback.
func update_charges_tag() -> void:
	var owned: OwnedTags = pawn.owned_tags if pawn else null
	if owned == null:
		return
	var source := "charges:%d" % get_instance_id()
	if has_charges_tag == &"" or (uses_charges() and charges_left() <= 0):
		owned.clear_source(source)
	else:
		owned.set_source(source, [has_charges_tag])


func _charges_changed() -> void:
	update_charges_tag()
	if manager:
		manager.readiness_changed()


## True if this property rolls back, either way.
func keeps_state(property: String) -> bool:
	return get_pushed_properties().has(property) or get_rollback_properties().has(property)


## Records a pushed property's new value in the state store, from the next commit on (state store spec 6.3). Each property in
## [method get_pushed_properties] calls it from its setter, after setting the value. Nothing until the manager has registered them.
func push_state(property: StringName, value: Variant) -> void:
	if _tick_state:
		var key: Variant = _pushed_keys.get(property)
		if key != null:
			_tick_state.push_value(key, value)


## How many ticks a timed run lasts at the match's rate: duration_ticks, or max_steps_ticks when stepped. Dash and Knockback
## override it.
func run_length_ticks() -> int:
	if is_stepped(): # its steps decide when it ends; this is only the most it can run
		return TickDriver.ticks_at_rate(max_steps_ticks)
	return TickDriver.ticks_at_rate(duration_ticks)


## True if it runs for a while once started (a duration, steps, or a length of its own: Dash, Death, Knockback), so it keeps
## [member started_at] and [member ends_at]. False for one that happens at once, such as Jump.
func is_timed() -> bool:
	return duration_ticks > 0 or is_stepped()


## True while a timed run is going.
func is_running_timed() -> bool:
	return ends_at >= 0


## True once the current run is over: the manager finishes it on this pawn's run. Set by [method end_run], or by reaching ends_at.
func is_run_over() -> bool:
	return ends_at >= 0 and TickDriver.tick >= ends_at


## Ends the current run this tick: the manager finishes it (stopping its steps, starting its cooldown) before this run of the pawn is
## over. For steps that are done, and for an ability that decides its own end.
func end_run() -> void:
	if ends_at >= 0:
		ends_at = mini(ends_at, TickDriver.tick)


## Moves the current run's deadlines this many ticks later, as if it hadn't run for them: the manager calls it while an action pauses
## locomotion (a Dash), so a timed locomotion's time waits. An ability with deadlines of its own moves them too, with [code]super()[/code].
func delay_run(ticks: int) -> void:
	if ends_at >= 0 and ends_at != NEVER:
		started_at += ticks
		ends_at += ticks


## Ticks since the current run started, through this tick; 0 when not running. Worked out from [member started_at], so it rolls back.
func ticks_running() -> int:
	return maxi(TickDriver.tick - started_at, 0) if ends_at >= 0 else 0


## For [method tick]: the ticks of the run that came before this run of the pawn (0 on its first tick). This run covers
## [method ticks_elapsed] more.
func ticks_before_this_run() -> int:
	return maxi(TickDriver.tick - ticks_elapsed() - started_at, 0) if ends_at >= 0 else 0


## Ticks left of the current run, from [member ends_at]; 0 when not running. For readouts.
func ticks_left() -> int:
	return maxi(ends_at - TickDriver.tick, 0) if ends_at >= 0 else 0


## Ticks until it can start again, from [member ready_at]; 0 when ready. For readouts.
func cooldown_ticks_left() -> int:
	return maxi(ready_at - TickDriver.tick, 0)


## Ticks a waiting press has left in its buffer, from [member buffer_until]; 0 with none. For readouts.
func buffer_ticks_left() -> int:
	return maxi(buffer_until - TickDriver.tick, 0)


## True while a press waits in its buffer.
func is_buffered() -> bool:
	return TickDriver.tick < buffer_until


## Called when a timed run starts or ends, also when a rollback loads new values. [DeathAbility] uses it to keep [code]Pawn.dead[/code] current.
func _running_changed(_running: bool) -> void:
	pass


# While a timed run goes, the pawn owns its category and extra categories (tag spec 3). From the ends_at setter, so a rollback or a
# snapshot that loads a run sets them too, on every machine.
func _set_owned_tags(running: bool) -> void:
	var owned: OwnedTags = pawn.owned_tags if pawn else null
	if owned == null:
		return
	if not running:
		owned.clear_source(self)
		return
	var tags: Array = extra_categories.duplicate()
	if category != &"":
		tags.push_front(category)
	owned.set_source(self, tags)


# --- Steps (pawn spec 8.20) ---


## The ticks this run covers: 1, or more for a pawn running every Nth tick (pawn spec 8.21). Timers and step counts advance by it.
func ticks_elapsed() -> int:
	return pawn.ticks_elapsed if pawn else 1


## True if it's built from steps.
func is_stepped() -> bool:
	return not steps.is_empty()


## The timeline it runs when its definition has none: none by default, so its steps run one after another. A kind that makes its own
## steps (MeleeAttack, RangedAttack) returns the timeline for them.
func default_timeline() -> Array[TimelineEntry]:
	return []


## Starts a step from code, as a bespoke script does (ability spec 6.4): its first entry not running, started again if it already ran.
## Steps not in the timeline have a manual entry for this.
func start_step(step: AbilityStep) -> void:
	if step == null or step.ability != self or step.running:
		return
	for e in timeline.size():
		if _entry_steps[e] == step:
			start_entry(e)
			return


## Stops a running step, passing the reason ("done", "released", "failed", "cancelled") to its [method AbilityStep.exit].
func stop_step(step: AbilityStep, reason := "cancelled") -> void:
	var e := running_entry_of(step)
	if e >= 0:
		stop_entry(e, reason)


## True while this step of this ability runs.
func is_step_running(step: AbilityStep) -> bool:
	return step != null and step.ability == self and running_entry_of(step) >= 0


## The timeline entry this step runs in now, or -1.
func running_entry_of(step: AbilityStep) -> int:
	for e in _entries_of_step.get(step, []):
		if _entry_running(e):
			return e
	return -1


## Ticks a running step has counted: since it started, less the ticks that didn't count ([method AbilityStep.counts_this_tick]).
## Inside its own [method AbilityStep.tick], the ticks before this one. 0 when not running.
func step_ticks_of(step: AbilityStep) -> int:
	var e := running_entry_of(step)
	if e < 0:
		return 0
	var counted: int = TickDriver.tick - timeline_state[e * _SLOTS + _ORIGIN]
	if step == _step_before_count:
		counted -= ticks_elapsed() # this tick isn't counted yet
	return maxi(counted, 0)


## Starts this timeline entry now: its values onto its step, then the step's enter(). Rules call it; code can too.
func start_entry(e: int) -> void:
	var step: AbilityStep = _entry_steps[e]
	if step.running:
		push_warning("%s: timeline entry %s can't start while step %s runs in another entry." % [name, timeline[e].get_label(), step.name])
		return
	# Counted per tick from the tick driver's number, so a replay counts the same way.
	var now: int = TickDriver.tick
	if now != _starts_tick:
		_starts_tick = now
		_starts_this_tick = 0
	_starts_this_tick += 1
	if _starts_this_tick > MAX_STEP_STARTS_PER_TICK:
		if not _warned_too_many_starts:
			_warned_too_many_starts = true
			push_warning("%s: more than %d steps started in one tick, so it's stopped. Check code that starts and stops steps in enter() or exit()." % [name, MAX_STEP_STARTS_PER_TICK])
		if _starts_this_tick == MAX_STEP_STARTS_PER_TICK + 1:
			end_run() # the manager finishes it, stopping its steps
		return
	_apply_values(e)
	_write_entry(e, now, -1, 0, now)
	step.enter()
	if manager:
		manager.readiness_version += 1 # a step's cancel window can change what may start
		manager.step_started.emit(self, step)


## Stops this running timeline entry with this reason ("done", "released", "failed" or "cancelled").
func stop_entry(e: int, reason := "cancelled") -> void:
	if not _entry_running(e):
		return
	var base := e * _SLOTS
	_write_entry(e, timeline_state[base + _STARTED], TickDriver.tick, _REASONS.get(reason, TimelineEntry.Reason.CANCELLED), timeline_state[base + _ORIGIN])
	var step: AbilityStep = _entry_steps[e]
	step.exit(reason)
	if manager:
		manager.readiness_version += 1
		manager.step_finished.emit(self, step, reason)


## The names of the steps running now, in tree order. For readouts and debug tools.
func get_running_step_names() -> PackedStringArray:
	var names := PackedStringArray()
	for step in steps:
		if step.running:
			names.append(String(step.name))
	return names


## Its interrupt_threshold now, before effects add: the strictest of its running steps' own, or its own when none has one.
func current_interrupt_threshold() -> int:
	var strictest := -1
	for step in steps:
		if step.running and step.interrupt_threshold >= 0:
			strictest = maxi(strictest, step.interrupt_threshold)
	return strictest if strictest >= 0 else interrupt_threshold


## True if this run of the ability has already hit this pawn.
func has_hit(target: Pawn) -> bool:
	return pawns_hit_this_run.has(target.entity_number())


## Notes that this run hit the pawn with this key ([method Pawn.entity_number]). False, with a warning once, if the run has hit
## [constant MAX_HITS_PER_RUN] already: then the pawn isn't hit.
func note_hit_key(key: int) -> bool:
	if pawns_hit_this_run.size() >= MAX_HITS_PER_RUN:
		if not _warned_hit_cap:
			_warned_hit_cap = true
			push_warning("%s: hit %d pawns in one run, its most; the rest aren't hit." % [name, MAX_HITS_PER_RUN])
		return false
	var listed := pawns_hit_this_run.duplicate()
	listed.append(key)
	pawns_hit_this_run = listed
	return true


# A hit on enemies with no effects of its own: the default when nothing names one.
static func _default_hit() -> HitDefinition:
	if _shared_default_hit == null:
		_shared_default_hit = HitDefinition.new()
	return _shared_default_hit


## Who its hits may hit and what they do now: one swapped in while playing, else its definition's, else a hit on enemies.
func hit_definition() -> HitDefinition:
	if _hit_swap:
		return _hit_swap
	if settings == null:
		prepare_settings()
	return settings.hit.resolved() as HitDefinition if settings.hit else _default_hit()


## Swaps who its hits may hit and what they do, while playing (an empowered state); null goes back to its definition's.
func use_hit_definition(hit: HitDefinition) -> void:
	_hit_swap = hit.resolved() as HitDefinition if hit else null


## Lands a hit its swing or projectile made on this pawn (ability spec 13.1): a [HitInfo] carrying the hit definition's effects and its
## own on-hit EffectApplier children, delivered to the target (its interceptors, then effects), then [signal hit_landed]. The one place
## a hit is applied; override it for an ability's own rules (damage falling off with distance), calling [code]super()[/code].
func land_hit(target: Pawn, direction: Vector3, at_tick: int, _at: Vector3, with: HitDefinition = null) -> HitInfo:
	var using := with if with else hit_definition()
	var target_effects := on_hit_effects
	var self_effects := on_hit_self_effects
	if not using.target_effects.is_empty() or not using.attacker_effects.is_empty():
		target_effects = on_hit_effects.duplicate()
		self_effects = on_hit_self_effects.duplicate()
		for effect in using.target_effects:
			if effect:
				effect.register() # so an over-time one is recognised by id on every machine
				target_effects.append(effect)
		for effect in using.attacker_effects:
			if effect:
				effect.register()
				self_effects.append(effect)
	if target_effects.is_empty() and self_effects.is_empty() and not _warned_no_effects:
		_warned_no_effects = true
		push_warning("%s hit %s but has no on-hit effects (EffectApplier children or its hit definition's), so the hit does nothing." % [name, target.name])
	var hit := HitInfo.make(pawn, self, target, direction, at_tick, target_effects, self_effects)
	hit.deliver()
	return hit


## Its swing's record of this run: whom it hit and what it met. Made the first time it's asked for; cleared as the ability starts.
func get_hit_run() -> HitRun:
	if hit_run == null:
		hit_run = HitRun.new(self, &"pawns_hit_this_run")
		hit_run.ability = self
		hit_run.on_intersect = func(entry: Dictionary) -> void: intersected.emit(entry)
	hit_run.team = pawn.team if pawn else 0
	return hit_run


## Called by the manager when the ability has no [HitInterceptor], so it can make its defaults (Dash, Parry). Nothing by default.
func make_default_interceptors() -> void:
	pass


## Called once by the manager: finds the [AbilityStep] children and works out its [member timeline].
func collect_steps() -> void:
	steps.clear()
	for child in get_children():
		if child is AbilityStep:
			child.ability = self
			child.pawn = pawn
			steps.append(child)
	for step in steps:
		step.setup_hold() # which action it watches, before its own setup
	_build_timeline()
	for step in steps:
		step.setup()


## Called by the manager when the ability starts: clears the timeline's state and starts the entries due at its start.
func begin_steps() -> void:
	var cleared := PackedInt32Array()
	cleared.resize(timeline.size() * _SLOTS)
	for e in timeline.size():
		var base := e * _SLOTS
		cleared[base + _STARTED] = -1
		cleared[base + _ENDED] = -1
		cleared[base + _ORIGIN] = -1
	timeline_state = cleared
	_capture_base_values()
	_start_due_entries()


var _running_now: Array[int] = [] # run_steps' working list, kept between ticks so it isn't made anew every tick

## Called by the manager every tick the ability runs, after [method tick]: ticks each running step (in timeline order), then starts the
## entries whose rules now hold. A step done or released starts what follows it; one that fails ends them all. The ability ends when
## no step that keeps it running runs and no entry is due.
func run_steps(dt: float) -> void:
	# The entries running as this tick began. Those started during it get their first tick on the next one.
	_running_now.clear()
	for e in timeline.size():
		if _entry_running(e):
			_running_now.append(e)
	var now: int = TickDriver.tick
	var elapsed := ticks_elapsed()
	for e in _running_now:
		if not _entry_running(e):
			continue # an earlier step stopped it this tick
		var step: AbilityStep = _entry_steps[e]
		_step_before_count = step # its step_ticks don't include this tick yet
		# Let go, it ends before its tick, with "released" (which starts what follows it, as done does).
		if step.ends_when_released and step.hold_bit != 0 and not step.is_held() and step.can_end_on_release():
			_step_before_count = null
			stop_entry(e, "released")
			continue
		var status := step.tick(dt)
		var counts := step.counts_this_tick()
		_step_before_count = null
		if not counts:
			# This tick didn't count: its count starts later. A deadline, moved on only while it waits.
			var base := e * _SLOTS
			_write_entry(e, timeline_state[base + _STARTED], -1, 0, timeline_state[base + _ORIGIN] + elapsed)
		var length := step.length() # asked once: it converts for the tick rate each time
		if status == AbilityStep.Status.RUNNING and length > 0 and now - timeline_state[e * _SLOTS + _ORIGIN] >= length:
			status = AbilityStep.Status.DONE
		if status == AbilityStep.Status.DONE:
			stop_entry(e, "done")
		elif status == AbilityStep.Status.FAILED:
			stop_entry(e, "failed")
			end_steps("failed")
			end_run()
			return
	_start_due_entries()
	# Running while a step that keeps it running does, or an entry is still due; steps that only go along stop then.
	for e in timeline.size():
		if _entry_running(e) and _entry_steps[e].keeps_ability_running:
			return
		if _entry_due(e):
			return
	end_steps("done")
	end_run() # no step left: the ability is over, and the manager finishes it


## Stops every running step with this reason, and puts back the step values its entries changed. The manager calls it when the
## ability finishes or is cancelled.
func end_steps(reason := "cancelled") -> void:
	for e in timeline.size():
		if _entry_running(e):
			stop_entry(e, reason)
	_restore_base_values()


## After a rollback loads its state: the running entries' values go back onto their steps.
func timeline_loaded() -> void:
	if timeline_state.size() != timeline.size() * _SLOTS:
		return
	for e in timeline.size():
		if _entry_running(e):
			_apply_values(e)


## The steps whose entries start when an entry of this step ends: what comes after it, for visuals (a windup's sweep).
func steps_after(step: AbilityStep) -> Array[AbilityStep]:
	var out: Array[AbilityStep] = []
	for e in _entries_of_step.get(step, []):
		for f in timeline.size():
			if _entry_after[f] == e and timeline[f].after_event == TimelineEntry.After.ENDS and not out.has(_entry_steps[f]):
				out.append(_entry_steps[f])
	return out


## The step whose end starts this step's first entry, or null: what came before it, for visuals (a recovery's sweep).
func step_before(step: AbilityStep) -> AbilityStep:
	for e in _entries_of_step.get(step, []):
		var before := _entry_after[e]
		if before >= 0 and timeline[e].after_event == TimelineEntry.After.ENDS:
			return _entry_steps[before]
	return null


# The slots of an entry in timeline_state.
const _SLOTS := 4
const _STARTED := 0
const _ENDED := 1
const _REASON := 2
const _ORIGIN := 3
const _REASONS := {"done": TimelineEntry.Reason.DONE, "released": TimelineEntry.Reason.RELEASED, "failed": TimelineEntry.Reason.FAILED, "cancelled": TimelineEntry.Reason.CANCELLED}
# Worked out by _build_timeline, never state: each entry's step, the entry its "after" names (-1), and its at_tick in this match's ticks.
var _entry_steps: Array[AbilityStep] = []
var _entry_after := PackedInt32Array()
var _entry_at := PackedInt32Array()
var _entry_delay := PackedInt32Array()
var _entries_of_step := {} # step -> its entries
var _value_keys := {} # step -> the properties any entry changes on it
var _base_values := {} # step -> {property: its own value}, captured as a run begins
var _step_before_count: AbilityStep = null # the step whose tick is in progress, so its step_ticks leave this tick out


func _entry_running(e: int) -> bool:
	var base := e * _SLOTS
	return timeline_state[base + _STARTED] >= 0 and timeline_state[base + _ENDED] < 0


# Writes an entry's four numbers and pushes the array once.
func _write_entry(e: int, started: int, ended: int, reason: int, origin: int) -> void:
	var base := e * _SLOTS
	if timeline_state[base + _STARTED] == started and timeline_state[base + _ENDED] == ended and timeline_state[base + _REASON] == reason \
			and timeline_state[base + _ORIGIN] == origin:
		return
	# GDScript doesn't call a property's setter for an element write, so the array is changed here and pushed once.
	timeline_state[base + _STARTED] = started
	timeline_state[base + _ENDED] = ended
	timeline_state[base + _REASON] = reason
	timeline_state[base + _ORIGIN] = origin
	push_state(&"timeline_state", timeline_state)


# Starts, in list order, the entries not yet started whose rule holds; one started can start others in the same pass.
func _start_due_entries() -> void:
	var started_any := true
	var passes := 0
	while started_any and passes <= timeline.size():
		started_any = false
		passes += 1
		for e in timeline.size():
			if timeline_state[e * _SLOTS + _STARTED] < 0 and _rule_holds(e):
				start_entry(e)
				started_any = started_any or _entry_running(e)


func _rule_holds(e: int) -> bool:
	var entry := timeline[e]
	if entry.manual:
		return false
	if entry.starts_with_ability():
		return true
	var now: int = TickDriver.tick
	if _entry_at[e] >= 0 and now >= started_at + _entry_at[e]:
		return true
	var other := _entry_after[e]
	if other >= 0:
		var base := other * _SLOTS
		if entry.after_event == TimelineEntry.After.STARTS:
			if timeline_state[base + _STARTED] >= 0 and now >= timeline_state[base + _STARTED] + _entry_delay[e]:
				return true
		elif timeline_state[base + _ENDED] >= 0 and timeline_state[base + _REASON] & entry.end_reasons != 0 \
				and now >= timeline_state[base + _ENDED] + _entry_delay[e]:
			return true
	return entry.condition != null and entry.condition.holds(self)


# True if a rule will start this entry later without anything else happening first: a time not reached, an entry it follows still to
# run or end, or a delay still running. A condition alone doesn't keep the ability going.
func _entry_due(e: int) -> bool:
	if timeline_state[e * _SLOTS + _STARTED] >= 0 or timeline[e].manual:
		return false
	if _entry_at[e] >= 0:
		return true # not started, so its time hasn't come
	var other := _entry_after[e]
	if other < 0:
		return false
	var base := other * _SLOTS
	if timeline[e].after_event == TimelineEntry.After.STARTS:
		return timeline_state[base + _STARTED] >= 0 or _entry_due(other)
	if timeline_state[base + _ENDED] >= 0:
		return timeline_state[base + _REASON] & timeline[e].end_reasons != 0 # ended the right way, its delay still running
	return _entry_running(other) or _entry_due(other)


# Works out the timeline from the definition, the kind's default or the steps' order, and checks it once: entries naming a step it
# doesn't have, an "after" naming no entry, labels used twice, and entries that follow each other round in a loop.
func _build_timeline() -> void:
	var source: Array[TimelineEntry] = []
	if settings and not settings.step_timeline.is_empty():
		source = settings.step_timeline
	else:
		source = default_timeline()
	if source.is_empty():
		for i in steps.size():
			source.append(TimelineEntry.at(steps[i].name) if i == 0 else TimelineEntry.after_end_of(steps[i].name, steps[i - 1].name))
	var by_name := {}
	for step in steps:
		by_name[step.name] = step
	timeline.clear()
	_entry_steps.clear()
	for entry in source:
		if entry == null:
			continue
		if not by_name.has(entry.step):
			push_warning("%s: its step timeline names step '%s', which it doesn't have; that entry is left out." % [name, entry.step])
			continue
		timeline.append(entry)
		_entry_steps.append(by_name[entry.step])
	# Every step can be started from code, so one none of the entries names gets a manual entry.
	for step in steps:
		if not _entry_steps.has(step):
			var manual := TimelineEntry.new()
			manual.step = step.name
			manual.manual = true
			timeline.append(manual)
			_entry_steps.append(step)
	var by_label := {}
	for e in timeline.size():
		var label := timeline[e].get_label()
		if by_label.has(label):
			push_warning("%s: two timeline entries are called '%s'; give one a label. \"after\" finds the first." % [name, label])
		else:
			by_label[label] = e
	var count := timeline.size()
	_entry_after.resize(count)
	_entry_at.resize(count)
	_entry_delay.resize(count)
	_entries_of_step.clear()
	_value_keys.clear()
	for e in count:
		var entry := timeline[e]
		_entry_after[e] = -1
		if entry.after != &"":
			if by_label.has(entry.after) and by_label[entry.after] != e:
				_entry_after[e] = by_label[entry.after]
			else:
				push_warning("%s: timeline entry '%s' follows '%s', which isn't another entry; it won't start after it." % [name, entry.get_label(), entry.after])
		_entry_at[e] = TickDriver.ticks_at_rate(entry.at_tick) if entry.at_tick > 0 else entry.at_tick
		_entry_delay[e] = TickDriver.ticks_at_rate(entry.delay_ticks) if entry.delay_ticks > 0 else 0
		var step: AbilityStep = _entry_steps[e]
		if not _entries_of_step.has(step):
			_entries_of_step[step] = []
		_entries_of_step[step].append(e)
		for key in entry.values:
			if not _value_keys.has(step):
				_value_keys[step] = []
			if not _value_keys[step].has(key):
				_value_keys[step].append(key)
	for e in count:
		if _follows_round(e):
			push_warning("%s: timeline entry '%s' follows entries that lead back to it, so they can't start by their \"after\" rules." % [name, timeline[e].get_label()])
	var cleared := PackedInt32Array()
	cleared.resize(count * _SLOTS)
	for e in count:
		cleared[e * _SLOTS + _STARTED] = -1
		cleared[e * _SLOTS + _ENDED] = -1
		cleared[e * _SLOTS + _ORIGIN] = -1
	timeline_state = cleared


# True if following "after" from this entry comes back to it.
func _follows_round(e: int) -> bool:
	var at := _entry_after[e]
	var steps_taken := 0
	while at >= 0 and steps_taken <= timeline.size():
		if at == e:
			return true
		at = _entry_after[at]
		steps_taken += 1
	return false


# The values its step had before this run's entries changed any, so an entry without a value for a property gets the step's own.
func _capture_base_values() -> void:
	_base_values.clear()
	for step in _value_keys:
		var own := {}
		for key in _value_keys[step]:
			own[key] = step.get(key)
		_base_values[step] = own


func _apply_values(e: int) -> void:
	var step: AbilityStep = _entry_steps[e]
	if not _value_keys.has(step):
		return
	var own: Dictionary = _base_values.get(step, {})
	for key in _value_keys[step]:
		if timeline[e].values.has(key):
			step.set(key, timeline[e].values[key])
		elif own.has(key):
			step.set(key, own[key])


func _restore_base_values() -> void:
	for step in _base_values:
		for key in _base_values[step]:
			step.set(key, _base_values[step][key])


## Where its weapon is now, from the first running step that says, as an offset from the pawn's feet for this facing in radians; null if
## none. For visuals and animation.
func weapon_point(facing: float) -> Variant:
	for step in steps:
		if step.running:
			var point: Variant = step.weapon_point(facing)
			if point != null:
				return point
	return null



# --- The pawn's input, from its ControllerManager (pawn spec 8.17): "nothing pressed" for a pawn without one ---


## The direction the pawn is told to go, in world space, up to length 1.
func move_input() -> Vector3:
	return pawn.controller_manager.move_input if pawn and pawn.controller_manager else Vector3.ZERO


## Where the pawn is told to look, around the vertical, in radians.
func look_yaw() -> float:
	return pawn.controller_manager.look_yaw if pawn and pawn.controller_manager else (pawn.yaw if pawn else 0.0)


## How far away a target may be for the AI to use this as an attack, in metres; 0 means it isn't an attack. The AI's Attack behaviour
## reads it, so any attack (melee, ranged, a game's own) can be driven by one behaviour.
func attack_reach() -> float:
	return 0.0


## How many ticks behind its own the controller drew other pawns, for lag compensation.
func view_ticks_behind() -> float:
	return pawn.controller_manager.view_ticks_behind if pawn and pawn.controller_manager else 0.0


## The held actions this tick, as InputActions bits.
func held_actions() -> int:
	return pawn.controller_manager.held_actions if pawn and pawn.controller_manager else 0


## The held actions last tick, as InputActions bits, so a press can be told from a hold.
func previous_held_actions() -> int:
	return pawn.controller_manager.previous_held_actions if pawn and pawn.controller_manager else 0


## A stat from the pawn's StatManager, or fallback if there's no such stat or no StatManager.
func read_stat(stat_name: StringName, fallback: float) -> float:
	if pawn and pawn.stat_manager:
		return pawn.stat_manager.get_value(stat_name, fallback)
	return fallback


# --- Override these ---


## Extra conditions for starting, such as being on the ground. Cooldowns, lockouts and combos are already checked.
func can_start() -> bool:
	return true


## Once, when it starts.
func start() -> void:
	pass


## Every tick it runs.
func tick(_dt: float) -> void:
	pass


## Once, when it stops, finished or cancelled.
func stop() -> void:
	pass


## Every tick, running or not. Only called on abilities whose script overrides it.
func every_tick(_dt: float) -> void:
	pass


## True if it's fine with the pawn sleeping (pawn spec 15.3). Only an ability that overrides [method every_tick] needs to answer: false
## while it would still change something. Jump answers false until its time off the ground is back to 0.
func can_sleep() -> bool:
	return true


## True if the pawn may sleep while it runs (pawn spec 15.3); its timer and tick wait with the pawn. Death answers true while Health is 0.
## Asked every tick the pawn could otherwise sleep, so keep it cheap.
func can_sleep_while_running() -> bool:
	return false
