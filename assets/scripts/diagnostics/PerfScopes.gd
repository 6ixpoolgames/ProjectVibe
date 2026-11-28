# Written by Claude (claude-opus-5-5), 2026-11-16. History: diagnostics/CHANGELOG.md.
## Timing scopes: systems mark the work they do, and a diagnostics tool reads how long each took, frame by frame.
##
## When nothing is listening ([member enabled] off, as in a game without [DiagnosticsManager]) a scope costs one boolean check, so the
## marks stay in shipping code. Names are dotted, general first ("ai.sensing"), so a tool can add up a group; one name used many
## times a frame (once per pawn) adds up its times and counts its calls. Main thread only: the totals aren't guarded for threads, and
## work on worker threads is timed by whoever waits for it.
## [codeblock]
## var started := PerfScopes.begin()       # 0 when nothing is listening, else the time now
## PerfScopes.end(&"ai.sensing", started)  # adds the time since begin() to this frame's "ai.sensing"
## [/codeblock]
## A scope that runs very often (one per behaviour per pawn per tick) uses [method begin_detailed]: a scope costs about a microsecond,
## so these only time while [member detailed] is on (F4 switches it on while open; so does [code]mass_battle_measure --scopes[/code]).
## Off, the two calls still cost about 0.25 microseconds; in the hottest paths (every pawn or step every tick) check [member detailed]
## first, which costs about 0.07:
## [codeblock]
## var started := PerfScopes.begin_detailed() if PerfScopes.detailed else 0
## step.tick(dt)
## if started != 0:
##     PerfScopes.end(&"step.FollowStep", started)
## [/codeblock]
## Design: diagnostics spec.
class_name PerfScopes
extends RefCounted

## On while a tool is listening. Off, [method begin] returns 0 and [method end] does nothing.
static var enabled := false
## On while a tool wants the fine-grained scopes too ([method begin_detailed]). Off by default.
static var detailed := false

static var _totals := {} # name -> [microseconds, count], this frame


## The time now, in microseconds, to hand to [method end]; 0 when nothing is listening.
static func begin() -> int:
	return Time.get_ticks_usec() if enabled else 0


## [method begin] for a scope that runs very often: times only while both [member enabled] and [member detailed] are on, else 0.
static func begin_detailed() -> int:
	return Time.get_ticks_usec() if enabled and detailed else 0


## Adds the time since [code]started[/code] (from [method begin]) to the name's total for this frame. Does nothing if it is 0.
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


## Adds a time measured some other way (microseconds), such as one a C++ class reports.
static func add(name: StringName, microseconds: int, count := 1) -> void:
	if not enabled:
		return
	var entry: Variant = _totals.get(name)
	if entry == null:
		_totals[name] = [microseconds, count]
	else:
		entry[0] += microseconds
		entry[1] += count


## Everything timed since the last call as name -> [microseconds, count], and starts afresh.
static func take_frame() -> Dictionary:
	var frame := _totals
	_totals = {}
	return frame
