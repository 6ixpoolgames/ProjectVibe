# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## A replay channel of events: things that happen at a moment (replay spec section 3).
##
## Each event is a kind, a pawn's replay id (0 for none) and a Dictionary of plain values (never objects, so a file can't carry
## code). Spawns, world, gameplay and diagnostics extend it. Anything calls [method add_event]; the next tick writes it, except
## during a rollback replay (it already happened once).
## [br]
## A tick's bytes: on a keyframe the snapshot (put_var of a Dictionary: the channel's state now, such as every live pawn); the
## event count (u16); per event its kind (UTF-8), pawn id (u32) and data (put_var).
## [br]
## Reading: [code]state["events"][/code] holds this tick's events as [code]{tick, kind, id, data}[/code]. An extending channel keeps
## lasting state by overriding [method snapshot], [method read_snapshot] and [method apply_event].
## Design: replay spec 3.
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


## Notes an event for the next tick. [code]kind[/code] is a short name such as "died"; [code]id[/code] the pawn's replay id, or 0.
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
