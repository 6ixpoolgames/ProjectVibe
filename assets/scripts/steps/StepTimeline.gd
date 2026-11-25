# Written by Claude (claude-opus-5-5), 2026-11-24. History: steps/CHANGELOG.md.
## Runs an owner's [Step] children on a timeline of [TimelineEntry] rules (pawn spec 16.7, ability spec 6.2).
##
## Each ability owns one (and each AI behaviour will). Entries start at a tick, when another entry starts or ends (with a delay), or on
## a condition; steps end on their length or when they say done; several run at once, and one step can run in several entries. The
## timeline's state is four numbers per entry ([member state]), which its owner rolls back as one value.
## [br][br]The owner (the host) is told what happens through these methods, which it must have:
## [codeblock]
## _timeline_state_written()                  # state changed: push it for rollback
## _timeline_step_started(step)               # a step entered
## _timeline_step_finished(step, reason)      # a step exited
## _timeline_runaway()                        # too many starts in one tick: end the run
## [/codeblock]
## Conditions are asked about the host. A host whose steps write a pawn's input also has [code]step_input()[/code] ([MoveStep]).
class_name StepTimeline
extends RefCounted

## The most steps one timeline may start in one tick, a guard against steps that start and stop each other in a loop. Past it, starts
## are refused, the host is told to end its run, and it warns once.
const MAX_STARTS_PER_TICK := 32

## What [method run] found.
enum Result {
	RUNNING, ## a step that keeps the owner running runs, or an entry is still due
	DONE, ## nothing left: every step has stopped with "done"
	FAILED, ## a step failed: every step has stopped with "failed"
}

## Its steps in tree order.
var steps: Array[Step] = []
## The entries it runs: the source given to [method build], plus a manual entry for each step none names.
var entries: Array[TimelineEntry] = []
## Four numbers per entry: the tick it started, the tick it ended (-1: not yet), why it ended ([enum TimelineEntry.Reason], 0 none) and
## where its step's count starts (the start, moved on by ticks that didn't count). A step that only waits out its length changes
## nothing while it runs. Set it only to load a saved state, then call [method loaded].
var state := PackedInt32Array()
## The tick the current run began, for entries that start at a tick.
var started_at := -1
## The owner it reports to; see the class description.
var host: Object = null
## For warnings: the owner's name.
var owner_name := ""

# The slots of an entry in state.
const _SLOTS := 4
const _STARTED := 0
const _ENDED := 1
const _REASON := 2
const _ORIGIN := 3
const _REASONS := {"done": TimelineEntry.Reason.DONE, "released": TimelineEntry.Reason.RELEASED, "failed": TimelineEntry.Reason.FAILED, "cancelled": TimelineEntry.Reason.CANCELLED}

# Worked out by build, never state: each entry's step, the entry its "after" names (-1), and its at_tick in this match's ticks.
var _entry_steps: Array[Step] = []
var _entry_after := PackedInt32Array()
var _entry_at := PackedInt32Array()
var _entry_delay := PackedInt32Array()
var _entries_of_step := {} # step -> its entries
var _value_keys := {} # step -> the properties any entry changes on it
var _base_values := {} # step -> {property: its own value}, captured as a run begins
var _step_before_count: Step = null # the step whose tick is in progress, so its step_ticks leave this tick out
var _elapsed := 1 # the ticks the current run() covers
var _running_now: Array[int] = [] # run's working list, kept between ticks so it isn't made anew every tick
var _starts_tick := -1 # the tick _starts_this_tick counts for
var _starts_this_tick := 0
var _warned_too_many_starts := false


func _init(owner_host: Object = null, name_for_warnings := "") -> void:
	host = owner_host
	owner_name = name_for_warnings


## Works out the entries from these steps and source entries (empty: the steps one after another in tree order) and checks them once:
## entries naming a step it doesn't have, an "after" naming no entry, labels used twice, and entries that follow each other in a loop.
## Then each step's [method Step.setup].
func build(new_steps: Array[Step], source: Array[TimelineEntry]) -> void:
	steps = new_steps
	for step in steps:
		step.timeline = self
	if source.is_empty():
		source = []
		for i in steps.size():
			source.append(TimelineEntry.at(steps[i].name) if i == 0 else TimelineEntry.after_end_of(steps[i].name, steps[i - 1].name))
	var by_name := {}
	for step in steps:
		by_name[step.name] = step
	entries.clear()
	_entry_steps.clear()
	for entry in source:
		if entry == null:
			continue
		if not by_name.has(entry.step):
			push_warning("%s: its step timeline names step '%s', which it doesn't have; that entry is left out." % [owner_name, entry.step])
			continue
		entries.append(entry)
		_entry_steps.append(by_name[entry.step])
	# Every step can be started from code, so one none of the entries names gets a manual entry.
	for step in steps:
		if not _entry_steps.has(step):
			var manual := TimelineEntry.new()
			manual.step = step.name
			manual.manual = true
			entries.append(manual)
			_entry_steps.append(step)
	var by_label := {}
	for e in entries.size():
		var label := entries[e].get_label()
		if by_label.has(label):
			push_warning("%s: two timeline entries are called '%s'; give one a label. \"after\" finds the first." % [owner_name, label])
		else:
			by_label[label] = e
	var count := entries.size()
	_entry_after.resize(count)
	_entry_at.resize(count)
	_entry_delay.resize(count)
	_entries_of_step.clear()
	_value_keys.clear()
	for e in count:
		var entry := entries[e]
		_entry_after[e] = -1
		if entry.after != &"":
			if by_label.has(entry.after) and by_label[entry.after] != e:
				_entry_after[e] = by_label[entry.after]
			else:
				push_warning("%s: timeline entry '%s' follows '%s', which isn't another entry; it won't start after it." % [owner_name, entry.get_label(), entry.after])
		_entry_at[e] = TickDriver.ticks_at_rate(entry.at_tick) if entry.at_tick > 0 else entry.at_tick
		_entry_delay[e] = TickDriver.ticks_at_rate(entry.delay_ticks) if entry.delay_ticks > 0 else 0
		var step: Step = _entry_steps[e]
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
			push_warning("%s: timeline entry '%s' follows entries that lead back to it, so they can't start by their \"after\" rules." % [owner_name, entries[e].get_label()])
	state = _cleared()
	for step in steps:
		step.setup()


## True if it has steps.
func has_steps() -> bool:
	return not steps.is_empty()


## A run begins on this tick: clears the state and starts the entries due at once.
func begin(start_tick: int) -> void:
	started_at = start_tick
	state = _cleared()
	_state_written()
	_capture_base_values()
	_start_due_entries()


## Every tick of a run, covering [param elapsed] ticks (more than 1 for a pawn on a load step): ticks each running step in entry order,
## then starts the entries whose rules now hold. A step done or released starts what follows it; one that fails stops them all.
func run(dt: float, elapsed: int) -> Result:
	_elapsed = elapsed
	# The entries running as this tick began. Those started during it get their first tick on the next one.
	_running_now.clear()
	for e in entries.size():
		if _entry_running(e):
			_running_now.append(e)
	var now: int = TickDriver.tick
	for e in _running_now:
		if not _entry_running(e):
			continue # an earlier step stopped it this tick
		var step: Step = _entry_steps[e]
		_step_before_count = step # its step_ticks don't include this tick yet
		if step.checks_release and step.released_now():
			_step_before_count = null
			stop_entry(e, "released")
			continue
		var status := step.tick(dt)
		var counts := step.counts_this_tick()
		_step_before_count = null
		if not counts:
			# This tick didn't count: its count starts later. A deadline, moved on only while it waits.
			var base := e * _SLOTS
			_write_entry(e, state[base + _STARTED], -1, 0, state[base + _ORIGIN] + elapsed)
		var length := step.length() # asked once: it converts for the tick rate each time
		if status == Step.Status.RUNNING and length > 0 and now - state[e * _SLOTS + _ORIGIN] >= length:
			status = Step.Status.DONE
		if status == Step.Status.DONE:
			stop_entry(e, "done")
		elif status == Step.Status.FAILED:
			stop_entry(e, "failed")
			end("failed")
			return Result.FAILED
	_start_due_entries()
	# Running while a step that keeps the owner running does, or an entry is still due; steps that only go along stop then.
	for e in entries.size():
		if _entry_running(e) and _entry_steps[e].keeps_owner_running:
			return Result.RUNNING
		if _entry_due(e):
			return Result.RUNNING
	end("done")
	return Result.DONE


## Stops every running step with this reason, and puts back the step values its entries changed.
func end(reason := "cancelled") -> void:
	for e in entries.size():
		if _entry_running(e):
			stop_entry(e, reason)
	_restore_base_values()


## After a rollback set [member state]: the running entries' values go back onto their steps.
func loaded() -> void:
	if state.size() != entries.size() * _SLOTS:
		return
	for e in entries.size():
		if _entry_running(e):
			_apply_values(e)


## Starts a step from code, as a bespoke script does (ability spec 6.4): its first entry not running, started again if it already ran.
## Steps no entry names have a manual entry for this.
func start_step(step: Step) -> void:
	if step == null or step.timeline != self or step.running:
		return
	for e in entries.size():
		if _entry_steps[e] == step:
			start_entry(e)
			return


## Stops a running step, passing the reason ("done", "released", "failed", "cancelled") to its [method Step.exit].
func stop_step(step: Step, reason := "cancelled") -> void:
	var e := running_entry_of(step)
	if e >= 0:
		stop_entry(e, reason)


## The entry this step runs in now, or -1.
func running_entry_of(step: Step) -> int:
	for e in _entries_of_step.get(step, []):
		if _entry_running(e):
			return e
	return -1


## Ticks a running step has counted: since it started, less the ticks that didn't count ([method Step.counts_this_tick]). Inside its
## own [method Step.tick], the ticks before this one. 0 when not running.
func step_ticks_of(step: Step) -> int:
	var e := running_entry_of(step)
	if e < 0:
		return 0
	var counted: int = TickDriver.tick - state[e * _SLOTS + _ORIGIN]
	if step == _step_before_count:
		counted -= _elapsed # this tick isn't counted yet
	return maxi(counted, 0)


## Starts this entry now: its values onto its step, then the step's enter(). Rules call it; code can too.
func start_entry(e: int) -> void:
	var step: Step = _entry_steps[e]
	if step.running:
		push_warning("%s: timeline entry %s can't start while step %s runs in another entry." % [owner_name, entries[e].get_label(), step.name])
		return
	# Counted per tick from the tick driver's number, so a replay counts the same way.
	var now: int = TickDriver.tick
	if now != _starts_tick:
		_starts_tick = now
		_starts_this_tick = 0
	_starts_this_tick += 1
	if _starts_this_tick > MAX_STARTS_PER_TICK:
		if not _warned_too_many_starts:
			_warned_too_many_starts = true
			push_warning("%s: more than %d steps started in one tick, so it's stopped. Check code that starts and stops steps in enter() or exit()." % [owner_name, MAX_STARTS_PER_TICK])
		if _starts_this_tick == MAX_STARTS_PER_TICK + 1 and host:
			host._timeline_runaway()
		return
	_apply_values(e)
	_write_entry(e, now, -1, 0, now)
	step.enter()
	if host:
		host._timeline_step_started(step)


## Stops this running entry with this reason ("done", "released", "failed" or "cancelled").
func stop_entry(e: int, reason := "cancelled") -> void:
	if not _entry_running(e):
		return
	var base := e * _SLOTS
	_write_entry(e, state[base + _STARTED], TickDriver.tick, _REASONS.get(reason, TimelineEntry.Reason.CANCELLED), state[base + _ORIGIN])
	var step: Step = _entry_steps[e]
	step.exit(reason)
	if host:
		host._timeline_step_finished(step, reason)


## The names of the steps running now, in tree order. For readouts and debug tools.
func get_running_step_names() -> PackedStringArray:
	var names := PackedStringArray()
	for step in steps:
		if step.running:
			names.append(String(step.name))
	return names


## The steps whose entries start when an entry of this step ends: what comes after it, for visuals (a windup's sweep).
func steps_after(step: Step) -> Array[Step]:
	var out: Array[Step] = []
	for e in _entries_of_step.get(step, []):
		for f in entries.size():
			if _entry_after[f] == e and entries[f].after_event == TimelineEntry.After.ENDS and not out.has(_entry_steps[f]):
				out.append(_entry_steps[f])
	return out


## The step whose end starts this step's first entry, or null: what came before it, for visuals (a recovery's sweep).
func step_before(step: Step) -> Step:
	for e in _entries_of_step.get(step, []):
		var before := _entry_after[e]
		if before >= 0 and entries[e].after_event == TimelineEntry.After.ENDS:
			return _entry_steps[before]
	return null


# --- Internals ---


func _cleared() -> PackedInt32Array:
	var cleared := PackedInt32Array()
	cleared.resize(entries.size() * _SLOTS)
	for e in entries.size():
		var base := e * _SLOTS
		cleared[base + _STARTED] = -1
		cleared[base + _ENDED] = -1
		cleared[base + _ORIGIN] = -1
	return cleared


func _state_written() -> void:
	if host:
		host._timeline_state_written()


func _entry_running(e: int) -> bool:
	var base := e * _SLOTS
	return state[base + _STARTED] >= 0 and state[base + _ENDED] < 0


# Writes an entry's four numbers and tells the host once.
func _write_entry(e: int, started: int, ended: int, reason: int, origin: int) -> void:
	var base := e * _SLOTS
	if state[base + _STARTED] == started and state[base + _ENDED] == ended and state[base + _REASON] == reason and state[base + _ORIGIN] == origin:
		return
	state[base + _STARTED] = started
	state[base + _ENDED] = ended
	state[base + _REASON] = reason
	state[base + _ORIGIN] = origin
	_state_written()


# Starts, in list order, the entries not yet started whose rule holds; one started can start others in the same pass.
func _start_due_entries() -> void:
	var started_any := true
	var passes := 0
	while started_any and passes <= entries.size():
		started_any = false
		passes += 1
		for e in entries.size():
			if state[e * _SLOTS + _STARTED] < 0 and _rule_holds(e):
				start_entry(e)
				started_any = started_any or _entry_running(e)


func _rule_holds(e: int) -> bool:
	var entry := entries[e]
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
			if state[base + _STARTED] >= 0 and now >= state[base + _STARTED] + _entry_delay[e]:
				return true
		elif state[base + _ENDED] >= 0 and state[base + _REASON] & entry.end_reasons != 0 and now >= state[base + _ENDED] + _entry_delay[e]:
			return true
	return entry.condition != null and entry.condition.holds(host)


# True if a rule will start this entry later without anything else happening first: a time not reached, an entry it follows still to
# run or end, or a delay still running. A condition alone doesn't keep the owner going.
func _entry_due(e: int) -> bool:
	if state[e * _SLOTS + _STARTED] >= 0 or entries[e].manual:
		return false
	if _entry_at[e] >= 0:
		return true # not started, so its time hasn't come
	var other := _entry_after[e]
	if other < 0:
		return false
	var base := other * _SLOTS
	if entries[e].after_event == TimelineEntry.After.STARTS:
		return state[base + _STARTED] >= 0 or _entry_due(other)
	if state[base + _ENDED] >= 0:
		return state[base + _REASON] & entries[e].end_reasons != 0 # ended the right way, its delay still running
	return _entry_running(other) or _entry_due(other)


# True if following "after" from this entry comes back to it.
func _follows_round(e: int) -> bool:
	var at := _entry_after[e]
	var steps_taken := 0
	while at >= 0 and steps_taken <= entries.size():
		if at == e:
			return true
		at = _entry_after[at]
		steps_taken += 1
	return false


# The values its steps had before this run's entries changed any, so an entry without a value for a property gets the step's own.
func _capture_base_values() -> void:
	_base_values.clear()
	for step in _value_keys:
		var own := {}
		for key in _value_keys[step]:
			own[key] = step.get(key)
		_base_values[step] = own


func _apply_values(e: int) -> void:
	var step: Step = _entry_steps[e]
	if not _value_keys.has(step):
		return
	var own: Dictionary = _base_values.get(step, {})
	for key in _value_keys[step]:
		if entries[e].values.has(key):
			step.set(key, entries[e].values[key])
		elif own.has(key):
			step.set(key, own[key])


func _restore_base_values() -> void:
	for step in _base_values:
		for key in _base_values[step]:
			step.set(key, _base_values[step][key])
