# Written by Claude (claude-opus-5-5), 2026-11-20. History: diagnostics/CHANGELOG.md.
## Warns when an entity moved further in a tick than its velocity explains: something set its position instead of moving it or
## calling [method Pawn.teleport].
##
## A sanity check run after each tick by the [DiagnosticsManager], in every build. It reads only the state store: every layout with
## a "position" and a "velocity" column, comparing each entity's row for this tick with the one before. A move may be as long as the
## faster of the two velocities allows over the ticks its run covered, times [member allowance], plus the crowd mover's push, plus
## [member slack]. A pawn that
## teleported on this tick or the one before is let through. It warns once per entity, naming it, and counts every move it caught.
## It doesn't judge speeds themselves: a dash's velocity explains a dash's move.
## [br]The first pass, over every entity, is the store's own ([method StateStore.find_long_moves]); only the moves it finds too long
## are looked at here.
class_name MoveSanityCheck
extends RefCounted

## How much further than its velocity explains a move may go: 1.5 covers walking up a 45 degree slope on a flat velocity.
var allowance := 1.5
## Metres any move may add on top: snapping to the ground, steps, rounding.
var slack := 0.5
## Moves caught since it started, warned about or not.
var caught := 0
## Entities whose moves it compared on the last tick checked.
var checked_last_tick := 0

var _warned := {} # handle -> true: each entity is warned about once


## Compares every entity's move into this tick with what its velocity explains. dt: the tick's length in seconds.
func check(store: Object, tick: int, dt: float) -> void:
	checked_last_tick = 0
	if store == null or tick < 1:
		return
	var found: Dictionary = store.find_long_moves(tick, dt, allowance, slack)
	checked_last_tick = found["checked"]
	var handles: PackedInt64Array = found["handles"]
	var moved: PackedFloat32Array = found["moved"]
	var speeds: PackedFloat32Array = found["speeds"]
	for i in handles.size():
		_look_closer(store, handles[i], tick, moved[i], speeds[i], dt)


# A move past the one-tick limit: rare, so only now is its owner looked up, for a pawn's ticks per run and its last teleport.
func _look_closer(store: Object, handle: int, tick: int, moved: float, speed: float, dt: float) -> void:
	var owner_node: Object = store.get_owner(handle)
	var entity: Object = owner_node.get_parent() if owner_node is Node and owner_node.get_parent() else owner_node
	if entity is Pawn:
		var pawn := entity as Pawn
		if pawn.last_teleport_tick >= tick - 1:
			return
		# A pawn on a load step runs every few ticks, and its run covers them all.
		var seconds := dt * maxi(pawn.ticks_elapsed, 1)
		# The crowd mover's separation pushes a pawn apart from others at up to max_push_speed, on top of its own velocity, which the
		# push doesn't change. Over a run of 4 ticks that's up to 0.67 m, past the slack, even for a pawn standing still.
		var push := 0.0
		if pawn.mover is CrowdMover:
			push = (pawn.mover as CrowdMover).max_push_speed * seconds
		if moved <= speed * seconds * allowance + push + slack:
			return
	caught += 1
	if _warned.has(handle):
		return
	_warned[handle] = true
	push_warning("[MoveSanityCheck] %s moved %.2f m on tick %d, more than its velocity (%.2f m/s) explains: move it, or call Pawn.teleport" %
			[str(entity.name) if entity is Node else str(entity), moved, tick, speed])
