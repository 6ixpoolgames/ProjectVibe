# Written by Claude (claude-opus-5-5), 2026-11-19. History: pawn/CHANGELOG.md.
## Draws a pawn's Visual smoothly between ticks: it glides between where the body was after its last two runs, turns the model the
## same way, and fades network corrections out.
##
## The pawn makes one when it has a child called Visual, and tells it after every run ([method note_run]), after a rollback puts it
## back ([method snap]), and from the network hooks ([method note_moved], [method add_correction]). It only ever reads game state. A
## pawn running every Nth tick moves once per run, so its Visual glides across the whole run (pawn spec 8.21); a correction fades over
## about 100 ms, a quick slide rather than a jump (netcode spec 6.2).
class_name VisualSmoother
extends Node

var _pawn: Pawn = null
var _visual: Node3D = null
var _model: Node3D = null
var _driver: Node = null
var _previous_position := Vector3.ZERO # the body after the run before last, and after the last run
var _current_position := Vector3.ZERO
var _previous_yaw := 0.0
var _current_yaw := 0.0
var _correction_offset := Vector3.ZERO # what's left of a correction, fading to nothing
var _last_run_span := 1 # how many ticks the last run covered
var _last_run_tick := -1


## Starts smoothing this Visual of this pawn. The Visual is placed by this part, between ticks, not by the body.
func setup(pawn: Pawn, visual: Node3D) -> void:
	_pawn = pawn
	_visual = visual
	_visual.top_level = true
	_model = _visual.get_node_or_null(^"Model")
	_driver = pawn.get_node_or_null(^"/root/TickDriver")
	snap()


## A run just ended on this tick, covering span ticks: the Visual glides from where the last one left the body to where it is now.
func note_run(span: int, tick: int) -> void:
	_previous_position = _current_position
	_previous_yaw = _current_yaw
	_current_position = _pawn.global_position
	_current_yaw = _pawn.yaw
	_last_run_span = span
	_last_run_tick = tick


## The body was put somewhere without moving there (a rollback, a spawn): the Visual goes straight there.
func snap() -> void:
	_current_position = _pawn.global_position
	_previous_position = _current_position
	_current_yaw = _pawn.yaw
	_previous_yaw = _current_yaw


## On a client, for a pawn someone else controls: it was just moved between snapshots, so the Visual glides after it.
func note_moved() -> void:
	note_run(1, _last_run_tick)
	_last_run_span = 1


## On a client: a correction moved the body by this much. The Visual keeps where it was and catches up over about 100 ms.
func add_correction(jump: Vector3) -> void:
	_correction_offset += jump


func _process(delta: float) -> void:
	if _visual == null:
		return
	var started := PerfScopes.begin() # timed for diagnostics, in its animation category
	_correction_offset = _correction_offset.lerp(Vector3.ZERO, 1.0 - exp(-delta / 0.04))
	var fraction: float = _driver.get_interpolation_fraction() if _driver else 1.0
	if _last_run_span > 1 and _driver and _pawn.is_simulated_here():
		fraction = clampf((float(_driver.tick - _last_run_tick) + fraction) / float(_last_run_span), 0.0, 1.0)
	_visual.global_position = _previous_position.lerp(_current_position, fraction) + _correction_offset
	if _model:
		_model.rotation.y = lerp_angle(_previous_yaw, _current_yaw, fraction)
	PerfScopes.end(&"animation.smoothing", started)
