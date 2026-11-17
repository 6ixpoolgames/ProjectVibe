# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## A replay channel of events: things that happen at a moment (replay spec section 3).
##
## Each event is a kind, a pawn's replay id (0 for none) and a Dictionary of plain values. Spawns, world, gameplay and diagnostics
## extend it.
## [br]
## A tick's bytes: on a keyframe, the snapshot (put_var of a Dictionary: what this channel's state is right now, such as every live
## pawn); then the event count (u16), and for each event: its kind (UTF-8), the pawn id (u32), its data (put_var).
## [br]
## Recording: anything calls [method add_event] between this tick's write and the next, and the next write_tick writes it. Events that
## happen during a rollback replay are left out, since they already happened once (a client replays ticks it predicted).
## [br]
## Reading: state["events"] holds this tick's events only, as Dictionaries {tick, kind, id, data}. An extending channel keeps its own
## lasting state alongside, such as who's alive, by overriding [method snapshot], [method read_snapshot] and [method apply_event].
## [br]
## GDScript note: put_var is Godot's own encoding of a Variant. Only plain values go in (numbers, strings, vectors, arrays,
## dictionaries), never objects, so a file can't carry code.
class_name ReplayEventChannel
extends ReplayChannel

var _pending: Array = [] # [kind, id, data] since the last write
var _driver: Node = null


func begin(for_recorder: ReplayRecorder) -> void:
	super(for_recorder)
	_driver = for_recorder.get_node_or_null("/root/TickDriver")
	_pending.clear()


func end() -> void:
	_pending.clear()
	super()


## Notes an event, written with the next tick. kind is a short name such as "died"; id is the pawn's replay id, or 0.
func add_event(kind: String, id: int, data: Dictionary = {}) -> void:
	if recorder == null:
		return
	if _driver and _driver.is_resimulating():
		return
	_pending.append([kind, id, data])


func write_tick(_tick: int, out: StreamPeerBuffer, keyframe: bool) -> void:
	if keyframe:
		out.put_var(snapshot())
	out.put_u16(_pending.size())
	for event: Array in _pending:
		out.put_utf8_string(event[0])
		out.put_u32(event[1])
		out.put_var(event[2])
	_pending.clear()


func read_tick(tick: int, data: StreamPeerBuffer, keyframe: bool, state: Dictionary) -> void:
	if keyframe:
		var shot: Variant = data.get_var()
		read_snapshot(shot if shot is Dictionary else {}, state)
	var events: Array = []
	var count := data.get_u16()
	for i in count:
		var event := {"tick": tick, "kind": data.get_utf8_string(), "id": data.get_u32()}
		var values: Variant = data.get_var()
		event["data"] = values if values is Dictionary else {}
		events.append(event)
		apply_event(event, state)
	state["events"] = events


## Recording: this channel's lasting state right now, for a keyframe. Plain values only.
func snapshot() -> Dictionary:
	return {}


## Reading: a keyframe's snapshot, into state (which starts empty on a keyframe).
func read_snapshot(_shot: Dictionary, _state: Dictionary) -> void:
	pass


## Reading: an event, applied to the lasting state.
func apply_event(_event: Dictionary, _state: Dictionary) -> void:
	pass
