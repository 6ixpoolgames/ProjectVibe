# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## One thing a pawn can do, such as walk, jump, swing or dash: a child of the pawn's [AbilityManager].
##
## Its settings come from its [member definition], a Resource every pawn using it shares (ability spec 3); empty, it runs with its
## kind's defaults. Any setting reads and writes by name on the node ([code]ability.cooldown_ticks[/code]); code inside reads
## [member settings]. A quick ability can set base settings in [code]_init()[/code] instead, which go into a definition of its own.
## [br][br]Extend it: [method make_default_definition] for settings of its own, then [method can_start], [method start],
## [method tick], [method stop], and [method every_tick] with [method can_sleep] for counters that always run. LOCOMOTION abilities
## move the pawn every tick they're chosen (one at a time); ACTION ones start on their trigger action (players' keys and AI
## behaviours press the same actions) or a gameplay event ([member AbilityDefinition.trigger_event]). Ticks are at 60 a second.
## [br][br]It can be built from [AbilityStep] children (a windup, a turn, a swing). What it does to pawns is effects in its
## definition (start, running, and its hit's target and attacker effects). Rollback: what it keeps between ticks is named in
## [method get_pushed_properties] or [method get_rollback_properties]; the base covers its own timers and step state.
## Design: pawn spec 8, 8.20, 16.7.
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
var definition_fell_back: bool:
	get:
		return _definition_settings.fell_back
# Works out settings from the definition, the kind's defaults and what's written on the node (shared with AI behaviours).
var _definition_settings := DefinitionSettings.new(self)

# State that rolls back, pushed to the state store when it changes (push_state). Timers are tick deadlines, which don't change while
# they run (ability spec 4): nothing counts down, and a pawn running every Nth tick needs nothing special. Each setter tells the manager,
# which keeps the soonest deadline (pawn spec 15.2); a rollback loading values goes through them too.
## The tick the current (or last) timed run started.
var started_at := -1:
	set(value):
		if value == started_at:
			return
		started_at = value
		step_runner.started_at = value # its entries that start at a tick count from here, through delays and rollbacks
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
## The event starting it, while it starts from its trigger event ([member AbilityDefinition.trigger_event]): read it in
## [method start] (the hit, a push). Null otherwise.
var trigger_data: GameplayEventData = null
## Goes up by one whenever its charges change (spent, back, refilled, its most changed), so a readout or the AI can tell without
## asking every tick.
var charges_version := 0
## Its [AbilityStep] children in tree order, found by [method collect_steps]. Empty: no steps.
var steps: Array[AbilityStep] = []
## The [StepTimeline] that runs its steps (pawn spec 16.7), built by [method collect_steps].
var step_runner := StepTimeline.new()
var _made_default_steps := false # true when it had no steps of its own and made its kind's defaults (collect_steps)
## The entries its timeline runs (ability spec 6.2): its definition's [member AbilityDefinition.step_timeline], else its kind's default
## ([method default_timeline]), else its steps one after another in tree order; plus a manual entry for each step none names.
var timeline: Array[TimelineEntry]:
	get:
		return step_runner.entries
## Its timeline's state ([member StepTimeline.state]), rolled back as one value.
var timeline_state: PackedInt32Array:
	get:
		return step_runner.state
	set(value):
		if value == step_runner.state:
			return
		step_runner.set_state(value)
		push_state(&"timeline_state", value)
## [member ends_at] for a run with no end of its own yet (Death, while Health is 0).
const NEVER := 1 << 62
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
const _NO_EFFECTS: Array[Effect] = []
static var _shared_default_hit: HitDefinition = null
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


## Works out [member settings] from [member definition]: its kind's defaults with none, or with one of another kind (warning). Settings
## written on the node (a script's _init(), old scene values, [method make_definition_unique]) go into a variant of its own on top.
## The manager calls it as it collects its abilities; reading a setting before then calls it too. Returns the settings.
func prepare_settings() -> AbilityDefinition:
	settings = _definition_settings.resolve(definition) as AbilityDefinition
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
	var own := _definition_settings.make_own(definition) as AbilityDefinition
	use_definition(definition)
	return own


## True if it has settings of its own on top of its definition ([method make_definition_unique], its script's _init(), or values a
## scene sets on the node), not only the shared ones.
func has_own_settings() -> bool:
	return _definition_settings.own != null


## What to check about where its settings come from, for diagnostics: "fell back" (a definition of another kind), "embedded" (saved
## in a scene, a prototype tweak), "own settings" (written on the node), or "" when it runs with a definition file or its kind's defaults.
func definition_note() -> String:
	return _definition_settings.note(definition)


# Each kind's typed reference to its settings is set here (MeleeAttackAbility._melee).
func _settings_changed() -> void:
	pass


# Settings by name on the node (pawn spec 16.3): any setting of its definition's class, such as ability.cooldown_ticks, reads from
# its settings and writes into its own variant, for code outside the ability, scenes and quick abilities' _init()
# ("self.duration_ticks = 30"). Code inside an ability reads settings.<name> (or its kind's typed reference), which is typed and faster.
# A write is free before the manager sets it up, and after that only once it has its own variant (make_definition_unique).
func _get(property: StringName) -> Variant:
	if not _definition_settings.has_setting(property):
		return null
	if settings == null:
		prepare_settings()
	return settings.get(property)


func _set(property: StringName, value: Variant) -> bool:
	if not _definition_settings.has_setting(property):
		return false
	if _definition_settings.write(definition, property, value, manager != null) and settings != null:
		prepare_settings()
	return true


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
	if settings.cooldown_ticks > 0:
		out.append("ready_at")
	if settings.buffer_window_ticks > 0 and settings.trigger_action != &"":
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
	return settings.max_charges > 0


## Its most charges now: its own value (the definition's, or what [method set_max_charges] set) plus the changes still running. Never
## below 0.
func max_charges_now(at_tick := -1) -> int:
	var now := TickDriver.tick if at_tick < 0 else at_tick
	var most := max_charges_base if max_charges_base >= 0 else settings.max_charges
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
	if next_restore_tick < 0 and settings.recharges:
		next_restore_tick = TickDriver.tick + TickDriver.ticks_at_rate(settings.charge_restore_ticks)


## The manager calls this when a charge deadline passes: charges come back for every restore due by now, each counted from the last,
## and changes that ended are dropped.
func apply_charge_deadlines(now: int) -> void:
	while next_restore_tick >= 0 and now >= next_restore_tick:
		var back := charges_spent if settings.restore_all_charges else settings.charges_restored
		charges_spent = maxi(charges_spent - back, 0)
		next_restore_tick = next_restore_tick + TickDriver.ticks_at_rate(settings.charge_restore_ticks) if charges_spent > 0 and settings.recharges else -1
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
	if settings.has_charges_tag == &"" or (uses_charges() and charges_left() <= 0):
		owned.clear_source(source)
	else:
		owned.set_source(source, [settings.has_charges_tag])


func _charges_changed() -> void:
	charges_version += 1
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
		return TickDriver.ticks_at_rate(settings.max_steps_ticks)
	return TickDriver.ticks_at_rate(settings.duration_ticks)


## True if it runs for a while once started (a duration, steps, or a length of its own: Dash, Death, Knockback), so it keeps
## [member started_at] and [member ends_at]. False for one that happens at once, such as Jump.
func is_timed() -> bool:
	return settings.duration_ticks > 0 or is_stepped()


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
	var tags: Array = settings.extra_categories.duplicate()
	if settings.category != &"":
		tags.push_front(settings.category)
	owned.set_source(self, tags)


# --- Steps (pawn spec 8.20) ---


## The ticks this run covers: 1, or more for a pawn running every Nth tick (pawn spec 8.21). Timers and step counts advance by it.
func ticks_elapsed() -> int:
	return pawn.ticks_elapsed if pawn else 1


## True if it's built from steps.
func is_stepped() -> bool:
	return step_runner.has_steps()


## The timeline it runs when its definition has none: none by default, so its steps run one after another. A kind that makes its own
## steps (MeleeAttack, RangedAttack) returns the timeline for them.
func default_timeline() -> Array[TimelineEntry]:
	return []


## Starts a step from code, as a bespoke script does (ability spec 6.4). See [method StepTimeline.start_step].
func start_step(step: AbilityStep) -> void:
	step_runner.start_step(step)


## Stops a running step, passing the reason ("done", "released", "failed", "cancelled") to its [method Step.exit].
func stop_step(step: AbilityStep, reason := "cancelled") -> void:
	step_runner.stop_step(step, reason)


## True while this step of this ability runs.
func is_step_running(step: AbilityStep) -> bool:
	return step != null and step.ability == self and step_runner.running_entry_of(step) >= 0


## The timeline entry this step runs in now, or -1.
func running_entry_of(step: AbilityStep) -> int:
	return step_runner.running_entry_of(step)


## Ticks a running step has counted. See [method StepTimeline.step_ticks_of].
func step_ticks_of(step: AbilityStep) -> int:
	return step_runner.step_ticks_of(step)


## Starts this timeline entry now: its values onto its step, then the step's enter(). Rules call it; code can too.
func start_entry(e: int) -> void:
	step_runner.start_entry(e)


## Stops this running timeline entry with this reason ("done", "released", "failed" or "cancelled").
func stop_entry(e: int, reason := "cancelled") -> void:
	step_runner.stop_entry(e, reason)


## The names of the steps running now, in tree order. For readouts and debug tools.
func get_running_step_names() -> PackedStringArray:
	return step_runner.get_running_step_names()


## Its interrupt_threshold now, before effects add: the strictest of its running steps' own, or its own when none has one.
func current_interrupt_threshold() -> int:
	var strictest := -1
	for step in steps:
		if step.running and step.interrupt_threshold >= 0:
			strictest = maxi(strictest, step.interrupt_threshold)
	return strictest if strictest >= 0 else settings.interrupt_threshold


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


## The one place a hit is applied (ability spec 13.1): a [HitInfo] with the effects of [param with] (null: [method hit_definition]),
## delivered to the target, whose hit ability decides what it does; then [signal hit_landed]. Override it for an ability's own rules
## (damage falling off with distance), calling [code]super()[/code].
func land_hit(target: Pawn, direction: Vector3, at_tick: int, _at: Vector3, with: HitDefinition = null) -> HitInfo:
	var using := with if with else hit_definition()
	var target_effects := using.target_effects
	var self_effects := using.attacker_effects
	for effect in target_effects + self_effects:
		if effect:
			effect.register() # so an over-time one is recognised by id on every machine
	if target_effects.is_empty() and self_effects.is_empty() and not _warned_no_effects:
		_warned_no_effects = true
		push_warning("%s hit %s but its hit definition has no effects (target_effects, attacker_effects), so the hit does nothing." % [name, target.name])
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


## Called by the manager just before it starts from its trigger event, with the event: keep what its run needs before it starts (a
## push's length decides how long Knockback runs). [member trigger_data] is set too. Nothing by default.
func prepare_from_event(_event: GameplayEventData) -> void:
	pass


## The effects on its own pawn while it runs ([member AbilityDefinition.running_effects]), or its kind's default with none.
func running_effects_now() -> Array[Effect]:
	return settings.running_effects if not settings.running_effects.is_empty() else default_running_effects_now()


## Its kind's running effects when its definition names none (Dash, Parry). None by default.
func default_running_effects_now() -> Array[Effect]:
	return _NO_EFFECTS


## Called once by the manager: finds the [AbilityStep] children and builds its timeline from its definition's entries, else its kind's
## default ([method default_timeline]), else its steps one after another.
func collect_steps() -> void:
	if settings == null:
		prepare_settings() # its steps read them (which action they watch, its timeline)
	if not _has_step_children():
		_make_default_steps()
		_made_default_steps = _has_step_children()
	steps.clear()
	for child in get_children():
		if child is AbilityStep:
			child.ability = self
			child.pawn = pawn
			steps.append(child)
	for step in steps:
		step.setup_hold() # which action it watches, before its own setup
	var as_steps: Array[Step] = []
	as_steps.assign(steps)
	step_runner.host = self
	step_runner.owner_name = name
	step_runner.build(as_steps, settings.step_timeline if not settings.step_timeline.is_empty() else default_timeline())
	if _made_default_steps:
		_sync_default_steps()


## Called by the manager as the ability starts, just before [method start]: the steps it made take its settings again, in case they
## changed in play.
func prepare_start() -> void:
	if _made_default_steps:
		_sync_default_steps()


## True when it had no [AbilityStep] children of its own and made its kind's default steps ([method _make_default_steps]).
func made_default_steps() -> bool:
	return _made_default_steps


# Makes its kind's default steps as children, when it has none of its own. None by default; MeleeAttack and RangedAttack make theirs,
# named the same everywhere so a definition's own timeline can name them.
func _make_default_steps() -> void:
	pass


# Copies its settings onto the steps it made: as its steps are collected, and again as it starts. Only called when it made them.
func _sync_default_steps() -> void:
	pass


func _has_step_children() -> bool:
	for child in get_children():
		if child is AbilityStep:
			return true
	return false


## Called by the manager when the ability starts: clears the timeline's state and starts the entries due at its start.
func begin_steps() -> void:
	step_runner.begin(started_at)


## Called by the manager every tick the ability runs, after [method tick]: runs its timeline ([method StepTimeline.run]). The ability
## ends when no step that keeps it running runs and no entry is due, or when a step fails.
func run_steps(dt: float) -> void:
	if step_runner.run(dt, ticks_elapsed()) != StepTimeline.Result.RUNNING:
		end_run() # no step left, or one failed: the ability is over, and the manager finishes it


## Stops every running step with this reason, and puts back the step values its entries changed. The manager calls it when the
## ability finishes or is cancelled.
func end_steps(reason := "cancelled") -> void:
	step_runner.end(reason)


## After a rollback loads its state: the running entries' values go back onto their steps.
func timeline_loaded() -> void:
	step_runner.loaded()


## The steps whose entries start when an entry of this step ends: what comes after it, for visuals (a windup's sweep).
func steps_after(step: AbilityStep) -> Array[AbilityStep]:
	var out: Array[AbilityStep] = []
	out.assign(step_runner.steps_after(step))
	return out


## The step whose end starts this step's first entry, or null: what came before it, for visuals (a recovery's sweep).
func step_before(step: AbilityStep) -> AbilityStep:
	return step_runner.step_before(step) as AbilityStep


# What its timeline tells it (StepTimeline's host methods).
func _timeline_state_written() -> void:
	push_state(&"timeline_state", step_runner.state)


func _timeline_step_started(step: Step) -> void:
	if manager:
		manager.readiness_version += 1 # a step's cancel window can change what may start
		var effects: Array[Effect] = (step as AbilityStep).running_effects if step is AbilityStep else _NO_EFFECTS
		if not effects.is_empty() and pawn.status_manager:
			pawn.status_manager.apply_effects(effects, pawn, self)
		manager.step_started.emit(self, step)


func _timeline_step_finished(step: Step, reason: String) -> void:
	if manager:
		manager.readiness_version += 1
		if step is AbilityStep and pawn.status_manager:
			for effect in (step as AbilityStep).running_effects:
				if effect:
					pawn.status_manager.remove_effect(effect)
		manager.step_finished.emit(self, step, reason)


func _timeline_runaway() -> void:
	end_run() # the manager finishes it, stopping its steps


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


## The action its timeline's conditions mean by "its action" ([member StepCondition.action] left empty): its trigger_action.
func default_action() -> StringName:
	return settings.trigger_action if settings else &""


## A stat from the pawn's StatusManager, or fallback if there's no such stat or no StatusManager.
func read_stat(stat_name: StringName, fallback: float) -> float:
	if pawn and pawn.status_manager:
		return pawn.status_manager.get_value(stat_name, fallback)
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
