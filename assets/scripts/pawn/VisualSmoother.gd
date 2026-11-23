# Written by Claude (claude-opus-5-5), 2026-11-19. History: pawn/CHANGELOG.md.
## Draws a pawn's Visual smoothly between ticks: it glides between where the body was after its last two runs, turns the model the
## same way, and fades network corrections out.
##
## The pawn makes one when it has a child called Visual, and tells it after every run it finishes itself ([method note_run]), after
## a rollback or a teleport puts it somewhere ([method snap]), and from the network hooks ([method note_moved], [method add_correction]).
## It holds the pawn's slot in the [VisualPlacer], which places every Visual once a frame; the crowd mover tells the placer about its
## pawns' runs itself, all at once. It only ever reads game state. A pawn running every Nth tick moves once per run, so its Visual
## glides across the whole run (pawn spec 8.21); a correction fades over about 100 ms, a quick slide rather than a jump (netcode spec
## 6.2).
class_name VisualSmoother
extends Node

## This pawn's slot in the [VisualPlacer], or -1 while it's out of the tree.
var slot := -1

var _pawn: Pawn = null
var _visual: Node3D = null
var _model: Node3D = null
var _placer: VisualPlacer = null


func _init() -> void:
	set_process(false) # the VisualPlacer places it
	set_physics_process(false)


## Starts smoothing this Visual of this pawn. The Visual is placed by the VisualPlacer, between ticks, not by the body.
func setup(pawn: Pawn, visual: Node3D) -> void:
	_pawn = pawn
	_visual = visual
	_visual.top_level = true
	_model = _visual.get_node_or_null(^"Model")
	_take_slot()


## A run just ended on this tick, covering span ticks: the Visual glides from where the last one left the body to where it is now.
## Where the pawn isn't simulated here, every glide is one tick long.
func note_run(span: int, tick: int) -> void:
	if slot >= 0:
		_placer.placement.note_run(slot, _pawn.global_position, _pawn.yaw, span if _pawn.is_simulated_here() else 1, tick)


## The body was put somewhere without moving there (a rollback, a spawn, a teleport): the Visual goes straight there.
func snap() -> void:
	if slot >= 0:
		_placer.placement.snap(slot, _pawn.global_position, _pawn.yaw)


## On a client, for a pawn someone else controls: it was just moved between snapshots, so the Visual glides after it.
func note_moved() -> void:
	if slot >= 0:
		_placer.placement.note_moved(slot, _pawn.global_position, _pawn.yaw)


## On a client: a correction moved the body by this much. The Visual keeps where it was and catches up over about 100 ms.
func add_correction(jump: Vector3) -> void:
	if slot >= 0:
		_placer.placement.add_correction(slot, jump)


## What's left of a correction, still fading.
# REFACTOR: only a netcode test reads it; the test could ask the placer itself (pawn/CHANGELOG.md).
func get_correction_offset() -> Vector3:
	return _placer.placement.get_correction(slot) if slot >= 0 else Vector3.ZERO


func _enter_tree() -> void:
	if _visual and slot < 0: # back in the tree after setup
		_take_slot()


func _exit_tree() -> void:
	if slot >= 0:
		_placer.placement.remove(slot)
		slot = -1


func _take_slot() -> void:
	_placer = VisualPlacer.get_or_make(_pawn)
	slot = _placer.placement.add(_visual, _model, _pawn.global_position, _pawn.yaw)
