# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## One thing a pawn can do, such as walk, jump, swing or dash: a child of the pawn's [AbilityManager].
##
## Its settings come from its [member definition], a Resource every pawn using it shares (ability spec 3): the node holds that
## reference and its state, and reads each setting from the definition. Empty, it runs with its kind's defaults.
## [br][br]Extend it, override [method make_default_definition] for a kind with settings of its own, and override [method can_start],
## [method start], [method tick], [method stop] and, for counters that run all the time, [method every_tick] (with [method can_sleep]).
## A quick ability can instead set base settings in [code]_init()[/code]: they go into a definition of its own. LOCOMOTION abilities move the pawn every tick
## they're chosen (one runs at a time); ACTION abilities start on a press of their [member trigger_action], at once or for a
## [member duration]. Players' keys and AI behaviours press the same actions. Times are set in seconds and kept in ticks (60 a second).
## [br][br]Rollback: whatever an ability keeps between ticks must be named in [method get_pushed_properties] (its setter calls
## [method push_state]) or [method get_rollback_properties] (read at every commit); the base already covers its own timers and step
## state. It can also be built from [AbilityStep] children (a windup, a turn, a swing) and carry [HitInterceptor] children that stop
## hits while it runs.
## Design: pawn spec 8, 8.20, 8.23.
class_name AbilityBase
extends Node

enum Kind { LOCOMOTION, ACTION }

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
## From the definition: [member AbilityDefinition.duration].
var duration: float:
	get:
		if settings == null:
			prepare_settings()
		return settings.duration
	set(value):
		_write_setting(&"duration", value)
## From the definition: [member AbilityDefinition.cooldown].
var cooldown: float:
	get:
		if settings == null:
			prepare_settings()
		return settings.cooldown
	set(value):
		_write_setting(&"cooldown", value)
## From the definition: [member AbilityDefinition.locks_out].
var locks_out: Array[StringName]:
	get:
		if settings == null:
			prepare_settings()
		return settings.locks_out
	set(value):
		_write_setting(&"locks_out", value)
## From the definition: [member AbilityDefinition.buffer_window].
var buffer_window: float:
	get:
		if settings == null:
			prepare_settings()
		return settings.buffer_window
	set(value):
		_write_setting(&"buffer_window", value)
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
## From its EffectApplier children, collected once by the manager (pawn spec 8.11): on its own pawn when it starts; on a pawn it hits;
## on its own pawn when it hits. A [MeleeSweepStep] hands the last two to the [HitInfo].
var on_start_effects: Array[Effect] = []
var on_hit_effects: Array[Effect] = []
var on_hit_self_effects: Array[Effect] = []
## Its [HitInterceptor]s, under it or its steps, found by the manager (pawn spec 8.23).
var interceptors: Array[HitInterceptor] = []
## Its [AbilityStep] children in tree order, found by [method collect_steps]. Empty: no steps.
var steps: Array[AbilityStep] = []
## Its steps' state, one number per step: 0 not running, step_ticks + 1 running. Rolled back as one value (a value per step was slow
## at 150 pawns). Steps change their number through [method set_step_value].
var step_state := PackedInt32Array():
	set(value):
		if value == step_state:
			return
		step_state = value
		push_state(&"step_state", value)
## [member ends_at] for a run with no end of its own yet (Death, while Health is 0).
const NEVER := 1 << 62
## The most steps one ability may start in one tick, a guard against steps that start and stop each other in a loop. Past it, starts
## are refused, the ability ends and it warns once.
const MAX_STEP_STARTS_PER_TICK := 32
var _starts_tick := -1 # the tick _starts_this_tick counts for
## The pawns its steps have hit this run (instance ids), so each is hit once across all its sweeps. Server only, never in a replay;
## cleared when it starts.
var pawns_hit_this_run: Array[int] = []
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
		push_warning("[AbilityBase] %s: its definition %s is for another kind of ability; it runs with the %s defaults." 				% [_describe_node(), base.describe(), defaults.get_script().get_global_name()])
		definition_fell_back = true
		base = null
	var chosen: AbilityDefinition = base if base else defaults
	if _own_definition:
		_own_definition.based_on = chosen # its own changes on top of the definition, or of the kind's defaults
		chosen = _own_definition
	settings = chosen.resolved()
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
			push_error("[AbilityBase] %s: %s comes from its definition, which every pawn using it shares; give it another with use_definition(), or its own copy with make_definition_unique()." 					% [_describe_node(), setting])
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
		out.append("step_state") # every step's state, as one value
	if cooldown > 0.0:
		out.append("ready_at")
	if buffer_window > 0.0 and trigger_action != &"":
		out.append("buffer_until")
	return out


## Other properties on this node that roll back, read from the node at every commit: no setter needed, so the easy way for a quick
## ability, but each costs a read per pawn per tick. None in the base.
func get_rollback_properties() -> Array[String]:
	return []


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


## How many ticks a timed run lasts: duration in ticks, or max_steps_ticks when stepped. Dash and Knockback override it.
func duration_ticks() -> int:
	if is_stepped(): # its steps decide when it ends; this is only the most it can run
		return TickDriver.ticks_at_rate(max_steps_ticks)
	return manager.ticks_for(duration) if manager else 0


## True if it runs for a while once started (a duration, steps, or a length of its own: Dash, Death, Knockback), so it keeps
## [member started_at] and [member ends_at]. False for one that happens at once, such as Jump.
func is_timed() -> bool:
	return duration > 0.0 or is_stepped()


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


# --- Steps (pawn spec 8.20) ---


## The ticks this run covers: 1, or more for a pawn running every Nth tick (pawn spec 8.21). Timers and step counts advance by it.
func ticks_elapsed() -> int:
	return pawn.ticks_elapsed if pawn else 1


## True if it's built from steps.
func is_stepped() -> bool:
	return not steps.is_empty()


## Starts one of its steps if it isn't running. Steps call it to start others.
func start_step(step: AbilityStep) -> void:
	if step == null or step.ability != self or step.running:
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
			push_warning("%s: its steps started more than %d steps in one tick, so it's stopped. Check steps that start and stop each other in enter() or exit()." % [name, MAX_STEP_STARTS_PER_TICK])
		if _starts_this_tick == MAX_STEP_STARTS_PER_TICK + 1:
			end_run() # the manager finishes it, stopping its steps
		return
	step.running = true
	step.step_ticks = 0
	step.enter()
	if manager:
		manager.readiness_version += 1 # a step's cancel window can change what may start
		manager.step_started.emit(self, step)


## Stops a running step, passing the reason to its [method AbilityStep.exit].
func stop_step(step: AbilityStep, reason := "cancelled") -> void:
	if step == null or step.ability != self or not step.running:
		return
	step.running = false
	step.exit(reason)
	if manager:
		manager.readiness_version += 1
		manager.step_finished.emit(self, step, reason)


## Sets one step's number in [member step_state] and pushes the array. Writing one element directly wouldn't record it: GDScript
## doesn't call a property's setter for an element write, on a packed array as on any other.
func set_step_value(index: int, value: int) -> void:
	if step_state[index] == value:
		return
	step_state[index] = value
	push_state(&"step_state", step_state)


## True while this step of this ability runs.
func is_step_running(step: AbilityStep) -> bool:
	return step != null and step.ability == self and step.running


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


## Called by the manager when the ability has no [HitInterceptor], so it can make its defaults (Dash, Parry). Nothing by default.
func make_default_interceptors() -> void:
	pass


## Called once by the manager: finds the [AbilityStep] children and what each starts when it's done.
func collect_steps() -> void:
	steps.clear()
	for child in get_children():
		if child is AbilityStep:
			child.ability = self
			child.pawn = pawn
			child.index = steps.size() # its slot in step_state
			steps.append(child)
	step_state = PackedInt32Array()
	step_state.resize(steps.size()) # new entries are 0: no step running
	for step in steps:
		step.setup_hold() # which action it watches, before its own setup
		step.setup()
		step.next_steps.clear()
		for path in step.starts_when_finished:
			var next := step.get_node_or_null(path) as AbilityStep
			if next == null or next.ability != self:
				push_warning("%s: step %s's starts_when_finished has %s, which isn't another step of this ability." % [name, step.name, path])
				continue
			step.next_steps.append(next)


## Called by the manager when the ability starts: starts the steps marked starts_first, or else the first step.
func begin_steps() -> void:
	var any_first := false
	for step in steps:
		if step.starts_first:
			any_first = true
			start_step(step)
	if not any_first and not steps.is_empty():
		start_step(steps[0])


var _steps_this_tick: Array[AbilityStep] = [] # run_steps' working list, kept between ticks so it isn't made anew every tick

## Called by the manager every tick the ability runs, after [method tick]: ticks each running step in tree order. A step done starts its
## next steps; one that fails ends them all. With none left running the ability ends.
func run_steps(dt: float) -> void:
	# The steps running as this tick began. Those started during it get their first tick on the next one.
	_steps_this_tick.clear()
	for step in steps:
		if step.running:
			_steps_this_tick.append(step)
	for step in _steps_this_tick:
		if not step.running:
			continue # an earlier step stopped it this tick
		# Let go, it ends before its tick, with "released", and its next steps start as if it were done.
		if step.ends_when_released and step.hold_bit != 0 and not step.is_held() and step.can_end_on_release():
			stop_step(step, "released")
			for next in step.next_steps:
				start_step(next)
			continue
		var status := step.tick(dt)
		if step.counts_this_tick():
			step.step_ticks += ticks_elapsed() # every tick this run covers (pawn spec 8.21)
		var length := step.length() # asked once: it converts for the tick rate each time
		if status == AbilityStep.Status.RUNNING and length > 0 and step.step_ticks >= length:
			status = AbilityStep.Status.DONE
		if status == AbilityStep.Status.DONE:
			stop_step(step, "done")
			for next in step.next_steps:
				start_step(next)
		elif status == AbilityStep.Status.FAILED:
			stop_step(step, "failed")
			end_steps("failed")
			break
	# Running while a step that keeps it running is; steps that only go along (keeps_ability_running off) stop then.
	for step in steps:
		if step.running and step.keeps_ability_running:
			return
	end_steps("done")
	end_run() # no step left: the ability is over, and the manager finishes it


## Where its weapon is now, from the first running step that says, as an offset from the pawn's feet for this facing in radians; null if
## none. For visuals and animation.
func weapon_point(facing: float) -> Variant:
	for step in steps:
		if step.running:
			var point: Variant = step.weapon_point(facing)
			if point != null:
				return point
	return null


## Stops every running step with this reason. The manager calls it when the ability finishes or is cancelled.
func end_steps(reason := "cancelled") -> void:
	for step in steps:
		if step.running:
			stop_step(step, reason)


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
