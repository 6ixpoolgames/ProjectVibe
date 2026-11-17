# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## The base for one AI sense, such as sight: notices other pawns and writes what it found into memory.
##
## A child of the pawn's [AISensingManager]. A sense never decides anything: it writes into the pawn's [AIMemory], with a gain saying
## how strongly it noticed. Extend it and override [method get_range] (how far it reaches, so the manager's one shared query covers
## every sense), [method full_pass] (candidates are the other-team pawns in range) and [method refresh] (a cheap check of the current
## target between full passes). Only [SightSense] exists; hearing is deferred.
## Design: pawn spec 10.4 and 14.
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
