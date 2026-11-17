# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## The base for one AI sense, such as sight: notices other pawns and writes what it found into memory.
##
## A child of the pawn's AISensingManager. Pawn spec section 10.4. A sense never decides anything. It notices other pawns and writes
## what it found into the pawn's memory ([AIMemory]), with a gain that says how strongly it noticed them. Memory, states and
## behaviours don't care which sense it was.
## [br]
## How to make one: extend this and override any of:
## [br]- [method get_range]: how far it reaches, so the manager's one shared query is big enough for every sense
## [br]- [method full_pass]: on each full pass. candidates are the other-team pawns within range, from the manager's query
## [br]- [method refresh]: between full passes, a cheap check of the current target
## [br]
## t0 has only SightSense. Hearing is deferred (pawn spec section 14), and being hit is a state rule, not a sense.
class_name AISenseBase
extends Node

## Set by the AISensingManager.
var manager: AISensingManager = null
## The pawn this sense belongs to. Set by the AISensingManager.
var pawn: Pawn = null
## The timing scope names for its full passes and its refreshes, such as &"ai.sense.Sight.full" and &"ai.sense.Sight.refresh" (see
## [PerfScopes]). Made once by the manager.
var perf_full_name: StringName = &""
var perf_refresh_name: StringName = &""


func _init() -> void:
	set_process(false)
	set_physics_process(false)


## How far this sense reaches, in metres.
func get_range() -> float:
	return 0.0


## On each full pass. candidates are other-team pawns within the manager's query range.
func full_pass(_candidates: Array[Pawn], _tick: int) -> void:
	pass


## Between full passes, for the current target.
func refresh(_tick: int) -> void:
	pass
