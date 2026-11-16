## Written by Claude (claude-opus-5-5), 2026-11-07: the base for one thing a pawn can do, such as walk, jump or sprint. A child of the
## pawn's AbilityManager. Pawn spec section 8.
##
## An ability is pressed like a skill in an MMO or MOBA: its trigger_action (a named action from InputActions, such as &"jump") starts
## it. The player's keys and an AI behaviour press the same actions, so both reach the same ability through the same rules.
##
## Two kinds:
##   LOCOMOTION   moves the pawn, every tick it's chosen. Exactly one runs each tick. The one with no trigger_action (Walk) is the
##                default; one whose trigger_action is held (Sprint) runs instead while it can.
##   ACTION       starts on a press. With no duration it happens at once (Jump); with a duration it runs for that long.
##
## How to make one: extend this, set what's needed in _init(), and override any of:
##   can_start() -> bool    extra conditions, such as being on the ground. Cooldowns and lockouts are already checked
##   start()                once, when it starts. An action with no duration does its whole job here
##   tick(dt)               every tick it runs. A locomotion ability writes the pawn's velocity here
##   stop()                 once, when it stops
##   every_tick(dt)         every tick, running or not, for counters such as time off the ground. Claude 2026-11-09: only called on
##                          abilities that override it; such an ability also overrides can_sleep() (pawn spec 15.3)
## Times are set in seconds and kept in ticks, so they line up exactly between server and client.
##
## Rollback: what an ability keeps between ticks has to roll back. get_rollback_properties() names those properties, and the
## AbilityManager registers them with the pawn's TickStateComponent. The base already handles its own: ticks_left (only with a
## duration), cooldown_ticks_left (only with a cooldown) and buffer_ticks_left (only with a buffer window). They count down to 0, so
## they're small numbers on the network. An ability with more state adds it to the list.
##
## Claude 2026-11-16 (pawn spec 8.20, the owner's design): an ability can be built from steps, AbilityStep children such as a windup, a
## turn and a swing (abilities/steps/AbilityStep.gd says how they run). The ability still owns the rules: starting, priority, cooldown,
## the interrupt table, tags and effects. A stepped ability runs while any of its steps does, timed by ticks_left like any timed
## ability, with max_steps_ticks as its longest run. The AbilityManager runs the steps right after tick().
class_name AbilityBase
extends Node

enum Kind { LOCOMOTION, ACTION }

@export var kind := Kind.ACTION
## The named action that starts it, such as &"jump". Empty: only the manager starts it, as the default locomotion.
@export var trigger_action: StringName = &""
## What it is, as a tag such as &"movement.jump". Used for lockouts. Empty: nothing can lock it out.
@export var category: StringName = &""
## Claude 2026-11-10: more groups this ability belongs to, besides category, such as &"movement.advanced" for a dash, or a school and a
## range for an attack (&"school.magic", &"range.ranged"). It answers to all of them, for lockouts, cancels and the AI's searches
## (AbilityManager.action_for_tag): each is a group, so one rule covers every ability in it. All of them share one 64-bit mask, with
## every other ability tag; how strong it is stays in the interrupt numbers, not in tags.
@export var extra_categories: Array[StringName] = []
## When several abilities share a trigger_action, the highest priority that can start wins; then the first in the tree. Claude
## 2026-11-09: was lowest-wins; now it's higher-wins like interrupt_priority and behaviour scores (the owner's call). Among locomotion
## abilities whose action is held, the same. Claude 2026-11-10: effects on the pawn can add to it while they last
## (AbilityPriorityPart, pawn spec 8.11), which is how combos work; and to interrupt_priority and interrupt_threshold.
@export var priority := 0
## Claude 2026-11-16 (pawn spec 8.20, the owner's design): which positions of a combo this ability can fill: [1] for an opener, [2] for
## a second hit, [2, 3] for one that fits second or third. Positions are shared by every attack, light and heavy, so attacks mix and
## match. A follow-up (no 1 in its list) can start only while a combo window is open and the next position is in its list; give it a
## higher priority than the opener on its key, so it wins inside the window. Empty (the default): not part of combos (walking,
## dashing). The AbilityManager keeps the count (combo_position) and the window, which an OpenComboStep opens.
@export var combo_positions: Array[int] = []
## Claude 2026-11-09: a random offset, up to ± this much, added to priority each time a press picks between abilities on one action,
## like a behaviour's score_jitter. 0 (the default): none, so the order is always the same. The offset comes from the tick's own
## random numbers (TickDriver.tick_rng), so a rollback replay picks the same ability. Locomotion ignores it, because it's chosen every
## tick and would flicker.
@export var priority_jitter := 0.0
## Seconds. For an action, 0 means it happens at once. For locomotion, 0 means it runs as long as it's wanted.
@export_range(0.0, 60.0, 0.05, "or_greater") var duration := 0.0
## Seconds after it stops before it can start again.
@export_range(0.0, 60.0, 0.05, "or_greater") var cooldown := 0.0
## Categories that can't start, or steer, while this runs, such as &"movement" for an attack that roots the pawn.
@export var locks_out: Array[StringName] = []
## Seconds a press waits if the ability can't start yet, such as jump pressed just before landing. 0: a press is tried once.
@export_range(0.0, 2.0, 0.01, "or_greater") var buffer_window := 0.0
## Claude 2026-11-09: how strong this ability is at cancelling a running ability it conflicts with (pawn spec 8.6). Two abilities
## conflict when either one's locks_out covers the other's category. Walk 0, Sprint 10, Jump 5, Dash 20, knockback 30. Claude
## 2026-11-10: Dash 40 now, the one thing that cancels a knockback (threshold 35).
@export var interrupt_priority := 0
## Claude 2026-11-09: while this runs, a conflicting ability whose interrupt_priority is at least this cancels it and starts; a
## weaker one is locked out, as before. 100: nothing in t0 can cancel it. MeleeAttack uses 15, so Dash cancels a swing and Sprint
## doesn't. An action meant to be cancelled by sprinting (a reload, say) uses 10 or less; by just moving, 0.
@export var interrupt_threshold := 100
## Claude 2026-11-10: on: while this runs, hits don't land on the pawn: no damage, no knockback, nothing (invulnerability frames).
## Dash has it, the owner's call. It's read from the running timer, which rolls back, so a replay agrees about what was dodged.
@export var invulnerable_while_running := false
## Claude 2026-11-10: with invulnerable_while_running on, how long it lasts from the start of the run, in seconds. 0: the whole run.
## Dash uses 0.18 (the owner's call), so the end of its slow-down can be hit.
@export_range(0.0, 10.0, 0.01, "or_greater") var invulnerable_seconds := 0.0
## Claude 2026-11-10: categories that can always cancel this while it runs, whatever the interrupt numbers say, such as
## &"movement.jump" for an ability a jump should cut short. Empty (the default): only the numbers decide. For the exceptions a single
## ladder of numbers can't express. A category covers its children, as in locks_out.
@export var cancelled_by: Array[StringName] = []
## Claude 2026-11-10: on: while this runs, the pawn's locomotion (Walk, Sprint) doesn't run at all, so it neither steers nor slows the
## pawn and this ability's own movement isn't fought. Dash has it. Off (the default): a locked-out locomotion still slows the pawn to
## a stop, which is what an attack that roots the pawn wants.
@export var pauses_locomotion := false
## Claude 2026-11-16 (pawn spec 8.20): for an ability with steps, the longest it can run, in ticks at 60 a second, as a safety: it ends
## once no step runs, and at this at the latest. Ignored without steps.
@export_range(1, 6000, 1, "or_greater") var max_steps_ticks := 600

# State that rolls back. See the top of the file.
# Claude 2026-11-09: each timer tells the manager when it starts or reaches 0, so the manager only counts down the timers that are
# running (pawn spec 15.2). That includes a rollback loading new values, which writes them through these setters.
# GDScript note: inside its own setter, a variable's name means the stored value, so "ticks_left" there is the old value.
## ticks left of a timed run. 0: not running a timed run
var ticks_left := 0:
	set(value):
		var flips := (value > 0) != (ticks_left > 0)
		if manager and flips:
			manager.timers_changed()
		ticks_left = value
		if flips:
			_running_changed(value > 0) # Claude 2026-11-09 (scaling spec step 4)
## ticks until it can start again
var cooldown_ticks_left := 0:
	set(value):
		if manager and (value > 0) != (cooldown_ticks_left > 0):
			manager.timers_changed()
		cooldown_ticks_left = value
## ticks a waiting press has left
var buffer_ticks_left := 0:
	set(value):
		if manager and (value > 0) != (buffer_ticks_left > 0):
			manager.timers_changed()
		buffer_ticks_left = value

## Set by the AbilityManager.
var manager: AbilityManager = null
## Claude 2026-11-09: set by the AbilityManager: a number from this ability's name, for its priority_jitter's random offset.
var jitter_salt := 0
var pawn: Pawn = null
## This ability's category as bits, with its parents' bits too. Worked out once by the manager. Claude 2026-11-10: and its
## extra_categories', with theirs.
var category_mask := 0
## locks_out as bits. Worked out once by the manager.
var locks_out_mask := 0
## Claude 2026-11-10: cancelled_by as bits. Worked out once by the manager, so the check while playing is one bit test.
var cancelled_by_mask := 0
## Claude 2026-11-09: trigger_action's input bit (InputActions), or 0 with none. Worked out once by the manager, so a tick tests a bit
## instead of looking the name up (pawn spec 15.2).
var trigger_bit := 0
## Claude 2026-11-10 (pawn spec 8.11): what this ability applies, from its EffectApplier children, collected once by the manager.
## on_start_effects go on its own pawn when it starts. on_hit_effects go on a pawn it hits, and on_hit_self_effects on its own pawn
## when it hits; an ability that hits (MeleeAttack) hands both to the HitInfo.
var on_start_effects: Array[Effect] = []
var on_hit_effects: Array[Effect] = []
var on_hit_self_effects: Array[Effect] = []
## Claude 2026-11-15: from EffectApplier children with ON_PARRY: what a parried attacker gets (on_parry_effects), and what this
## ability's own pawn gets (on_parry_self_effects). Only ParryAbility uses them.
var on_parry_effects: Array[Effect] = []
var on_parry_self_effects: Array[Effect] = []
## Claude 2026-11-16 (pawn spec 8.20): its AbilityStep children, in tree order, found by collect_steps(). Empty: no steps.
var steps: Array[AbilityStep] = []
## Claude 2026-11-16: its steps' state, one number per step: 0 while it isn't running, its step_ticks + 1 while it is. Rolled back as
## one value (steps read and write it through their running and step_ticks), because a value per step cost 2.4 ms a tick at 150 pawns.
var step_state := PackedInt32Array()
## Claude 2026-11-16, a safeguard (the owner asked): the most steps one ability may start in one tick. Each step runs at most once at a
## time, and one started during a tick waits for the next, so ordinary setups never get near this. It stops steps whose own code starts
## and stops each other in a loop within one tick: past it, starts are refused, the ability ends, and it warns once.
const MAX_STEP_STARTS_PER_TICK := 32
var _starts_tick := -1 # the tick _starts_this_tick counts for
## Claude 2026-11-16: the pawns its steps have hit this run (instance ids), so each is hit once across all its sweeps. On the server
## only, and never in a replay: hits are decided once, on the authority. Cleared when it starts.
var pawns_hit_this_run: Array[int] = []
var _starts_this_tick := 0
var _warned_too_many_starts := false


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## The properties on this node that roll back. Add to it with super() in an ability that keeps more.
func get_rollback_properties() -> Array[String]:
	var out: Array[String] = []
	if duration > 0.0 or is_stepped(): # Claude 2026-11-16: a stepped ability is timed too
		out.append("ticks_left")
	if is_stepped():
		out.append("step_state") # Claude 2026-11-16: every step's state, as one value
	if cooldown > 0.0:
		out.append("cooldown_ticks_left")
	if buffer_window > 0.0 and trigger_action != &"":
		out.append("buffer_ticks_left")
	return out


## Claude 2026-11-09: how many ticks a timed run lasts. The default turns duration's seconds into ticks; an ability that thinks in
## ticks, such as MeleeAttack with its phases, overrides this.
func duration_ticks() -> int:
	if is_stepped(): # Claude 2026-11-16 (pawn spec 8.20): its steps decide when it ends; this is only the most it can run
		return TickDriver.ticks_at_rate(max_steps_ticks)
	return manager.ticks_for(duration) if manager else 0


## True while a timed run is going.
func is_running_timed() -> bool:
	return ticks_left > 0


## Claude 2026-11-10: how many ticks of the current run have been ticked: 0 on the tick it starts, before its first tick. 0 when not
## running. Read from ticks_left, which rolls back, so it needs no state of its own.
func ticks_running() -> int:
	return duration_ticks() - ticks_left if ticks_left > 0 else 0


## Claude 2026-11-09 (scaling spec step 4): called whenever a timed run starts or ends, through the ticks_left setter, so also when a
## rollback loads new values. Nothing by default; DeathAbility uses it to keep Pawn.dead current.
func _running_changed(_running: bool) -> void:
	pass


# --- Steps (Claude 2026-11-16, pawn spec 8.20) ---


## Claude 2026-11-16 (pawn spec 8.21): the ticks this run of its pawn covers: 1 normally, more for a pawn running every Nth tick.
## Timers and step counts advance by it.
func ticks_elapsed() -> int:
	return pawn.ticks_elapsed if pawn else 1


## True if it's built from steps.
func is_stepped() -> bool:
	return not steps.is_empty()


## Starts a step of this ability, if it isn't running already. Steps call it to start others (a windup starting a turn).
func start_step(step: AbilityStep) -> void:
	if step == null or step.ability != self or step.running:
		return
	# The safeguard: counted per tick, from the tick driver's number, so a rollback replay counts the same way.
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
		manager.step_started.emit(self, step)


## Stops a running step of this ability, with this reason for its exit(). Nothing happens if it isn't running.
func stop_step(step: AbilityStep, reason := "cancelled") -> void:
	if step == null or step.ability != self or not step.running:
		return
	step.running = false
	step.exit(reason)
	if manager:
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


## Its interrupt_threshold right now, before what effects add: the strictest of its running steps' own, or its own when none of them
## has one. The AbilityManager reads this for cancelling (interrupt_threshold_now).
func current_interrupt_threshold() -> int:
	var strictest := -1
	for step in steps:
		if step.running and step.interrupt_threshold >= 0:
			strictest = maxi(strictest, step.interrupt_threshold)
	return strictest if strictest >= 0 else interrupt_threshold


## True while one of its running steps has invulnerable on.
func has_invulnerable_step() -> bool:
	for step in steps:
		if step.running and step.invulnerable:
			return true
	return false


## The AbilityManager calls this once, with its abilities: finds the AbilityStep children and what each starts when it's done.
func collect_steps() -> void:
	steps.clear()
	for child in get_children():
		if child is AbilityStep:
			child.ability = self
			child.pawn = pawn
			child.index = steps.size() # Claude 2026-11-16: its slot in step_state
			steps.append(child)
	step_state = PackedInt32Array()
	step_state.resize(steps.size()) # GDScript note: resize fills new entries with 0, so no step is running
	for step in steps:
		step.setup_hold() # Claude 2026-11-16: which action it watches, before its own setup
		step.setup() # Claude 2026-11-16
		step.next_steps.clear()
		for path in step.starts_when_finished:
			var next := step.get_node_or_null(path) as AbilityStep
			if next == null or next.ability != self:
				push_warning("%s: step %s's starts_when_finished has %s, which isn't another step of this ability." % [name, step.name, path])
				continue
			step.next_steps.append(next)


## The AbilityManager calls this when the ability starts: its first steps start (those marked starts_first, or else the first step).
func begin_steps() -> void:
	var any_first := false
	for step in steps:
		if step.starts_first:
			any_first = true
			start_step(step)
	if not any_first and not steps.is_empty():
		start_step(steps[0])


## The AbilityManager calls this every tick the ability runs, after tick(): each running step's tick, in tree order. A step done starts
## its next steps; a step that fails ends them all. With no step left running, the ability ends (ticks_left goes to 0).
func run_steps(dt: float) -> void:
	# The steps running as this tick began. Those started during it get their first tick on the next one.
	var this_tick: Array[AbilityStep] = []
	for step in steps:
		if step.running:
			this_tick.append(step)
	for step in this_tick:
		if not step.running:
			continue # an earlier step stopped it this tick
		# Claude 2026-11-16: let go, it ends before its tick, with "released", and its next steps start as if it were done.
		if step.ends_when_released and step.hold_bit != 0 and not step.is_held() and step.can_end_on_release():
			stop_step(step, "released")
			for next in step.next_steps:
				start_step(next)
			continue
		var status := step.tick(dt)
		if step.counts_this_tick():
			step.step_ticks += ticks_elapsed() # Claude 2026-11-16 (pawn spec 8.21): was 1
		if status == AbilityStep.Status.RUNNING and step.length() > 0 and step.step_ticks >= step.length():
			status = AbilityStep.Status.DONE
		if status == AbilityStep.Status.DONE:
			stop_step(step, "done")
			for next in step.next_steps:
				start_step(next)
		elif status == AbilityStep.Status.FAILED:
			stop_step(step, "failed")
			end_steps("failed")
			break
	# Claude 2026-11-16: running while a step that keeps it running is; steps that only go along (keeps_ability_running off) stop then.
	for step in steps:
		if step.running and step.keeps_ability_running:
			return
	end_steps("done")
	ticks_left = 0 # no step left: the ability is over, and the manager finishes it


## Claude 2026-11-16: where its weapon is now, from its running steps (the first that says), as an offset from the pawn's feet for this
## facing in radians; null if none says. For visuals and the animation module: they draw what the ability does.
func weapon_point(facing: float) -> Variant:
	for step in steps:
		if step.running:
			var point: Variant = step.weapon_point(facing)
			if point != null:
				return point
	return null


## Stops every running step, with this reason. The AbilityManager calls it when the ability finishes or is cancelled.
func end_steps(reason := "cancelled") -> void:
	for step in steps:
		if step.running:
			stop_step(step, reason)


# --- The pawn's input (Claude 2026-11-16 (pawn M4): it lives on the ControllerManager now; these read it, and give "nothing pressed" for a pawn
# without one, so no ability has to check) ---


## The direction the pawn is told to go, in world space, up to length 1.
func move_input() -> Vector3:
	return pawn.controller_manager.move_input if pawn and pawn.controller_manager else Vector3.ZERO


## Where the pawn is told to look, around the vertical, in radians.
func look_yaw() -> float:
	return pawn.controller_manager.look_yaw if pawn and pawn.controller_manager else (pawn.yaw if pawn else 0.0)


## How many ticks behind its own the controller was drawing other pawns, for lag compensation.
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


func can_start() -> bool:
	return true


func start() -> void:
	pass


func tick(_dt: float) -> void:
	pass


func stop() -> void:
	pass


func every_tick(_dt: float) -> void:
	pass


## Claude 2026-11-09: true if this ability is fine with the pawn sleeping (pawn spec 15.3): standing still, it skips its abilities,
## gravity and move_and_slide. Only an ability that overrides every_tick() needs to think about it: answer false while every_tick()
## would still change something with the pawn standing still. Jump answers false until its time off the ground is back to 0.
func can_sleep() -> bool:
	return true
