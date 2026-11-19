# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## One thing a pawn can do, such as walk, jump, swing or dash: a child of the pawn's [AbilityManager].
##
## Extend it, set what's needed in [code]_init()[/code], and override [method can_start], [method start], [method tick], [method stop]
## and, for counters that run all the time, [method every_tick] (with [method can_sleep]). LOCOMOTION abilities move the pawn every tick
## they're chosen (one runs at a time); ACTION abilities start on a press of their [member trigger_action], at once or for a
## [member duration]. Players' keys and AI behaviours press the same actions. Times are set in seconds and kept in ticks (60 a second).
## [br][br]Rollback: whatever an ability keeps between ticks must be named in [method get_rollback_properties]; the base already
## covers its own timers and step state. It can also be built from [AbilityStep] children (a windup, a turn, a swing) and carry
## [HitInterceptor] children that stop hits while it runs.
## Design: pawn spec 8, 8.20, 8.23.
class_name AbilityBase
extends Node

enum Kind { LOCOMOTION, ACTION }

@export var kind := Kind.ACTION
## The named action that starts it, such as &"jump". Empty: only the manager starts it, as the default locomotion.
@export var trigger_action: StringName = &""
## What it is, as a tag such as &"movement.jump". Used for lockouts. Empty: nothing can lock it out.
@export var category: StringName = &""
## More groups it belongs to besides category, such as &"movement.advanced" for a dash. Lockouts, cancels and
## [method AbilityManager.action_for_tag] answer to all of them. They share one 64-bit mask with every other ability tag.
@export var extra_categories: Array[StringName] = []
## Which ability a press picks among those on one action: the highest that can start wins, then the first in the tree. Locomotion
## with a held action works the same. Effects can add to it (AbilityPriorityPart, pawn spec 8.11).
@export var priority := 0
## Which combo positions it can fill: [1] an opener, [2] a second hit, [2, 3] second or third. A follow-up (no 1) starts only while the
## combo window is open; give it a higher priority than the opener so it wins there. Empty: not in combos. Pawn spec 8.20.
@export var combo_positions: Array[int] = []
## A random offset, up to plus or minus this, added to priority when a press picks between abilities. 0: none. It comes from the tick's
## own random numbers ([method TickDriver.tick_rng]), so a replay picks the same ability. Locomotion ignores it.
@export var priority_jitter := 0.0
## Seconds. For an action, 0 means it happens at once. For locomotion, 0 means it runs as long as it's wanted.
@export_range(0.0, 60.0, 0.05, "or_greater") var duration := 0.0
## Seconds after it stops before it can start again.
@export_range(0.0, 60.0, 0.05, "or_greater") var cooldown := 0.0
## Categories that can't start, or steer, while this runs, such as &"movement" for an attack that roots the pawn.
@export var locks_out: Array[StringName] = []
## Seconds a press waits if the ability can't start yet, such as jump pressed just before landing. 0: a press is tried once.
@export_range(0.0, 2.0, 0.01, "or_greater") var buffer_window := 0.0
## How hard it cancels a running ability it conflicts with (pawn spec 8.6): Walk 0, Jump 5, Sprint 10, Parry 10, MeleeAttack 15,
## Knockback 30, Dash 40, Death 1000.
@export var interrupt_priority := 0
## While it runs, a conflicting ability with at least this interrupt_priority cancels it; a weaker one is locked out. 100: only Death
## cancels it. MeleeAttack uses 15, so Dash cancels a swing and Sprint doesn't.
@export var interrupt_threshold := 100
# For invulnerability while it runs, give it an InvulnerabilityInterceptor child (HitInterceptor); Dash makes one by default.
## Categories that can always cancel it while it runs, whatever the interrupt numbers say, such as &"movement.jump". A category covers
## its children, as in locks_out.
@export var cancelled_by: Array[StringName] = []
## On: locomotion (Walk, Sprint) doesn't run at all while this does, so it neither steers nor slows the pawn (Dash). Off: a locked-out
## locomotion still slows the pawn to a stop, as an attack that roots the pawn wants.
@export var pauses_locomotion := false
## On: while it runs the pawn moves by physics ([code]move_and_slide[/code]), not the CrowdMover, so fast or forced moves such as Dash
## and Knockback collide properly. Pawn spec 8.22.
@export var needs_full_movement := false
## For a stepped ability, the longest it can run, in ticks at 60 a second. It ends when no step runs, or at this. Ignored without steps.
@export_range(1, 6000, 1, "or_greater") var max_steps_ticks := 600

# State that rolls back. Each setter tells the manager when its timer starts or reaches 0, so only running timers are counted down
# (pawn spec 15.2); a rollback loading values goes through them too.
## Ticks left of a timed run; 0: not running.
var ticks_left := 0:
	set(value):
		var flips := (value > 0) != (ticks_left > 0)
		if manager and flips:
			manager.timers_changed()
		ticks_left = value
		if flips:
			_running_changed(value > 0)
## Ticks until it can start again.
var cooldown_ticks_left := 0:
	set(value):
		if manager and (value > 0) != (cooldown_ticks_left > 0):
			manager.timers_changed()
		cooldown_ticks_left = value
## Ticks a waiting press has left.
var buffer_ticks_left := 0:
	set(value):
		if manager and (value > 0) != (buffer_ticks_left > 0):
			manager.timers_changed()
		buffer_ticks_left = value

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
## at 150 pawns).
var step_state := PackedInt32Array()
## The most steps one ability may start in one tick, a guard against steps that start and stop each other in a loop. Past it, starts
## are refused, the ability ends and it warns once.
const MAX_STEP_STARTS_PER_TICK := 32
var _starts_tick := -1 # the tick _starts_this_tick counts for
## The pawns its steps have hit this run (instance ids), so each is hit once across all its sweeps. Server only, never in a replay;
## cleared when it starts.
var pawns_hit_this_run: Array[int] = []
var _starts_this_tick := 0
var _warned_too_many_starts := false


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## The properties on this node that roll back. An ability that keeps more adds to it with [code]super()[/code].
func get_rollback_properties() -> Array[String]:
	var out: Array[String] = []
	if duration > 0.0 or is_stepped(): # a stepped ability is timed too
		out.append("ticks_left")
	if is_stepped():
		out.append("step_state") # every step's state, as one value
	if cooldown > 0.0:
		out.append("cooldown_ticks_left")
	if buffer_window > 0.0 and trigger_action != &"":
		out.append("buffer_ticks_left")
	return out


## How many ticks a timed run lasts: duration in ticks, or max_steps_ticks when stepped. Dash and Knockback override it.
func duration_ticks() -> int:
	if is_stepped(): # its steps decide when it ends; this is only the most it can run
		return TickDriver.ticks_at_rate(max_steps_ticks)
	return manager.ticks_for(duration) if manager else 0


## True while a timed run is going.
func is_running_timed() -> bool:
	return ticks_left > 0


## Ticks of the current run already ticked: 0 on the tick it starts, and when not running. Worked out from ticks_left, so it rolls back.
func ticks_running() -> int:
	return duration_ticks() - ticks_left if ticks_left > 0 else 0


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
			ticks_left = 0 # ends the ability: the manager finishes it, stopping its steps
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
	ticks_left = 0 # no step left: the ability is over, and the manager finishes it


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
