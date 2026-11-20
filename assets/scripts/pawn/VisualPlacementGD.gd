# Written by Claude (claude-opus-5-5), 2026-11-21. History: pawn/CHANGELOG.md.
## Places every pawn's Visual between ticks, in one call a frame: the GDScript twin of the C++ VisualPlacement, used where that
## library isn't available.
##
## Each slot is one drawn body: its Visual, its Model (turned, or none), where the body was after its last two runs and its yaw then,
## how many ticks the last run covered and when it ended, and what's left of a network correction. [method place] glides each Visual
## from the run before to the last one: by the tick driver's fraction, or across the whole run for a run longer than a tick (pawn spec
## 8.21); a correction fades out over about 100 ms (netcode spec 6.2). The [VisualPlacer] owns one and runs it each frame. Both twins
## do exactly the same; pawn/tests/visual_placement_selftest compares them.
class_name VisualPlacementGD
extends RefCounted

var _used := PackedByteArray()
var _visuals: Array[Object] = []
var _models: Array[Object] = []
var _previous_positions := PackedVector3Array()
var _current_positions := PackedVector3Array()
var _previous_yaws := PackedFloat64Array()
var _current_yaws := PackedFloat64Array()
var _corrections := PackedVector3Array()
var _spans := PackedInt64Array()
var _run_ticks := PackedInt64Array()
var _free: Array[int] = []
var _count := 0


## A new slot for this Visual and its Model (null: nothing turns), standing at position, facing yaw. Returns its number.
func add(visual: Object, model: Object, position: Vector3, yaw: float) -> int:
	var slot := _used.size()
	# The last freed slot first, as the C++ twin does.
	if not _free.is_empty():
		slot = _free.pop_back()
	else:
		_used.append(0)
		_visuals.append(null)
		_models.append(null)
		_previous_positions.append(Vector3.ZERO)
		_current_positions.append(Vector3.ZERO)
		_previous_yaws.append(0.0)
		_current_yaws.append(0.0)
		_corrections.append(Vector3.ZERO)
		_spans.append(1)
		_run_ticks.append(-1)
	_used[slot] = 1
	_visuals[slot] = visual
	_models[slot] = model
	_previous_positions[slot] = position
	_current_positions[slot] = position
	_previous_yaws[slot] = yaw
	_current_yaws[slot] = yaw
	_corrections[slot] = Vector3.ZERO
	_spans[slot] = 1
	_run_ticks[slot] = -1
	_count += 1
	return slot


## Frees a slot; its number is reused.
func remove(slot: int) -> void:
	if _has(slot):
		_used[slot] = 0
		_visuals[slot] = null
		_models[slot] = null
		_free.append(slot)
		_count -= 1


## The body was put somewhere without moving there (a rollback, a spawn, a teleport): its Visual goes straight there.
func snap(slot: int, position: Vector3, yaw: float) -> void:
	if _has(slot):
		_previous_positions[slot] = position
		_current_positions[slot] = position
		_previous_yaws[slot] = yaw
		_current_yaws[slot] = yaw


## A run ended on tick, covering span ticks: the Visual glides from where the last run left the body to position.
func note_run(slot: int, position: Vector3, yaw: float, span: int, tick: int) -> void:
	if _has(slot):
		_previous_positions[slot] = _current_positions[slot]
		_previous_yaws[slot] = _current_yaws[slot]
		_current_positions[slot] = position
		_current_yaws[slot] = yaw
		_spans[slot] = span
		_run_ticks[slot] = tick


## The same for many slots at once (the crowd mover's pawns); a slot below 0 is skipped.
func note_runs(slots: PackedInt64Array, positions: PackedVector3Array, yaws: PackedFloat32Array, spans: PackedInt64Array, tick: int) -> void:
	var count := slots.size()
	if positions.size() < count or yaws.size() < count or spans.size() < count:
		return
	for i in count:
		note_run(slots[i], positions[i], yaws[i], spans[i], tick)


## On a client, for a pawn someone else controls: moved between snapshots, so the Visual glides after it over one tick.
func note_moved(slot: int, position: Vector3, yaw: float) -> void:
	if _has(slot):
		note_run(slot, position, yaw, 1, _run_ticks[slot])


## On a client: a correction moved the body by jump. The Visual keeps where it was and catches up.
func add_correction(slot: int, jump: Vector3) -> void:
	if _has(slot):
		_corrections[slot] += jump


## What's left of a correction on this slot.
func get_correction(slot: int) -> Vector3:
	return _corrections[slot] if _has(slot) else Vector3.ZERO


## Places every slot's Visual: tick is the tick driver's, fraction how far it is towards the next, delta the frame's seconds.
## spans_runs: false without a tick driver, when every glide is one tick long.
func place(tick: int, fraction: float, delta: float, spans_runs: bool) -> void:
	var fade := 1.0 - exp(-delta / 0.04)
	for slot in _used.size():
		if _used[slot] == 0:
			continue
		# Checked before the cast: casting a freed object is an error.
		if not is_instance_valid(_visuals[slot]) or not (_visuals[slot] is Node3D):
			continue
		var visual: Node3D = _visuals[slot]
		_corrections[slot] = _corrections[slot].lerp(Vector3.ZERO, fade)
		var f := fraction
		# A run longer than a tick is glided across in full, so a pawn on a load step moves steadily (pawn spec 8.21).
		if _spans[slot] > 1 and spans_runs:
			f = clampf((float(tick - _run_ticks[slot]) + fraction) / float(_spans[slot]), 0.0, 1.0)
		visual.global_position = _previous_positions[slot].lerp(_current_positions[slot], f) + _corrections[slot]
		if is_instance_valid(_models[slot]) and _models[slot] is Node3D:
			var model: Node3D = _models[slot]
			model.rotation.y = lerp_angle(_previous_yaws[slot], _current_yaws[slot], f)


## Slots in use.
func get_count() -> int:
	return _count


func _has(slot: int) -> bool:
	return slot >= 0 and slot < _used.size() and _used[slot] == 1
