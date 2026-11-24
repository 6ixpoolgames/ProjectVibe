# Written by Claude (claude-opus-5-5), 2026-11-24. History: singletons/CHANGELOG.md.
## Actions booked for a tick and a point in it, run in a fixed order (netcode spec 19.4, pawn spec 16.9).
##
## Any system books an action with [method book]: what to call, the tick it's for, the point in that tick, and an order number. The
## tick driver that owns it ([member TickDriver.scheduler]) runs each point's due actions: [constant BEFORE_TICK] just before the tick's
## phases (delays such as respawns and body removal; objects come and go only between ticks), [constant AFTER_SIMULATE] once every
## participant has simulated (hit delivery). Within a point, actions run by tick, then order number, then the order they were booked
## in, so the result never depends on which entity happened to book first. An action booked for a tick that has passed runs at that
## point's next run; one whose object was freed is skipped. Pausing the tick driver pauses them all.
## [codeblock]
## TickDriver.scheduler.book(TickDriver.tick + TickDriver.ticks_at_rate(180), respawn.bind(pawn_number))
## [/codeblock]
## Tier 0 (v0) carries hit delivery and delays. Spawns and despawns, possession hand-offs and terrain edits join later, with the record
## that lets a replay land them on the same ticks.
class_name TickScheduler
extends RefCounted

## Points in a tick, in the order they come.
enum Point {
	BEFORE_TICK, ## Before the tick's phases, between ticks.
	AFTER_SIMULATE, ## After every participant has simulated, before record.
}

const NOT_DUE := 0x7FFFFFFFFFFFFFFF # no booking at a point

var _booked: Array = [[], []] # per point: entries [tick, order, booking number, Callable]
var _soonest := PackedInt64Array([NOT_DUE, NOT_DUE]) # per point: the earliest tick booked
var _bookings := 0 # booking numbers, so equal tick and order keep the order they were booked in


## Books [param action] for [param tick] at [param point]. Lower [param order] numbers run first among actions due together (hits
## use the attacker's and target's entity numbers).
func book(tick: int, action: Callable, point: Point = Point.BEFORE_TICK, order: int = 0) -> void:
	(_booked[point] as Array).append([tick, order, _bookings, action])
	_bookings += 1
	if tick < _soonest[point]:
		_soonest[point] = tick


## Runs every action booked at [param point] for [param tick] or earlier, in order, and returns how many came due. Actions booked
## while they run wait for the next run. The tick driver calls it; a test may too.
func run_due(point: Point, tick: int) -> int:
	if _soonest[point] > tick:
		return 0
	var due: Array = []
	var still: Array = []
	var soonest := NOT_DUE
	for entry: Array in _booked[point]:
		if entry[0] <= tick:
			due.append(entry)
		else:
			still.append(entry)
			soonest = mini(soonest, entry[0])
	_booked[point] = still
	_soonest[point] = soonest
	due.sort_custom(_runs_before)
	for entry: Array in due:
		var action: Callable = entry[3]
		if action.is_valid():
			action.call()
	return due.size()


## How many actions are booked at [param point] and not yet run.
func count(point: Point) -> int:
	return (_booked[point] as Array).size()


## Drops every booking. For a new match and for tests.
func clear() -> void:
	_booked = [[], []]
	_soonest = PackedInt64Array([NOT_DUE, NOT_DUE])


static func _runs_before(a: Array, b: Array) -> bool:
	if a[0] != b[0]:
		return a[0] < b[0]
	if a[1] != b[1]:
		return a[1] < b[1]
	return a[2] < b[2]
