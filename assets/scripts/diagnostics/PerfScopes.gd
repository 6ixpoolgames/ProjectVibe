# Written by Claude (claude-opus-5-5), 2026-11-16. History: diagnostics/CHANGELOG.md.
## Timing scopes: systems mark the work they do, and a diagnostics tool reads how long each took, frame by frame.
##
## The piece of diagnostics the rest of the base calls (the owner's call; docs/diagnostics/DIAGNOSTICS_SPEC.md). When nothing is
## listening ([member enabled] off, as in a game without [DiagnosticsManager]), a scope costs one check of a true-or-false, so the
## marks can stay in shipping code, as TickDriver's profile does (docs/TEST_AND_DEBUG_CODE.md).
## [br]
## How to mark work:
## [codeblock]
## var started := PerfScopes.begin()       # 0 when nothing is listening, else the time now
## # ... the work ...
## PerfScopes.end(&"ai.sensing", started)  # adds the time since begin() to "ai.sensing" for this frame
## [/codeblock]
## Names are dotted, from the general to the particular ("ai.sensing", "net.snapshots.send"), so a tool can add up a group ("ai").
## The same name can be used many times a frame, such as once per pawn: the times add up, and the count says how many.
## [br]
## How a tool reads them (DiagnosticsManager does, once a frame):
## [codeblock]
## PerfScopes.enabled = true
## var frame := PerfScopes.take_frame()  # name -> [microseconds, count] since the last take_frame(), and starts afresh
## [/codeblock]
## Main thread only: the totals aren't guarded for threads. Work on worker threads is timed by whoever waits for it.
## [br]
## Detail: a scope that runs very often, such as one per behaviour per pawn per tick, starts with [method begin_detailed] instead.
## It only times while [member detailed] is on as well, because a scope costs about a microsecond, and thousands a frame would change
## the numbers they're meant to show. The F4 timings panel switches it on while it's open, and [code]mass_battle_measure --scopes[/code]
## does too.
## [br]
## GDScript note: everything here is static, so it's used as PerfScopes.begin() with no object made, like TickJobs.
class_name PerfScopes
extends RefCounted

## On while a tool is listening. Off, begin() returns 0 and end() does nothing.
static var enabled := false
## On while a tool wants the fine-grained scopes too ([method begin_detailed]). Off by default.
static var detailed := false

static var _totals := {} # name -> [microseconds, count], this frame


## The time now, in microseconds, to hand to end(); or 0 when nothing is listening.
static func begin() -> int:
	return Time.get_ticks_usec() if enabled else 0


## begin() for a scope that runs very often: the time now only while both [member enabled] and [member detailed] are on, else 0.
## end() it as usual.
static func begin_detailed() -> int:
	return Time.get_ticks_usec() if enabled and detailed else 0


## Adds the time since started (from begin()) to name's total for this frame. Does nothing if started is 0.
static func end(name: StringName, started: int) -> void:
	if started == 0:
		return
	var spent := Time.get_ticks_usec() - started
	var entry: Variant = _totals.get(name)
	if entry == null:
		_totals[name] = [spent, 1]
	else:
		entry[0] += spent
		entry[1] += 1


## Adds a time measured some other way, in microseconds, such as one a C++ class reports.
static func add(name: StringName, microseconds: int, count := 1) -> void:
	if not enabled:
		return
	var entry: Variant = _totals.get(name)
	if entry == null:
		_totals[name] = [microseconds, count]
	else:
		entry[0] += microseconds
		entry[1] += count


## Everything timed since the last call, as name -> [microseconds, count], and starts afresh.
static func take_frame() -> Dictionary:
	var frame := _totals
	_totals = {}
	return frame
