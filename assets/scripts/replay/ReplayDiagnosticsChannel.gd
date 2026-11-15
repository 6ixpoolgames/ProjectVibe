## Written by Claude (claude-opus-5-5), 2026-11-16: replay channel 6, "diagnostics": how each frame went, recorded alongside the game
## (the owner's call: diagnostics hook into replay v0, so one recording holds what happened and what it cost; docs/diagnostics/
## DIAGNOSTICS_SPEC.md). It's a plain data channel in the base, like the others: something else fills it. In debug builds that's the
## DiagnosticsManager (diagnostics/), which adds this channel to the recorder; without it, nothing is recorded here.
##
## Frames and ticks aren't the same: a frame can run two ticks when it catches up, or none while paused. So each tick writes the frames
## that finished since the last tick, each with its own frame number.
##
## A tick's bytes:  on a keyframe, the snapshot (put_var: the scope names so far, so reading can start at any block); then the frame
##   count (u16), and for each frame:
##     frame number (u32); frame, physics, scripts and rest times (4 × f32, ms); physics steps (u8); drawing on the CPU and GPU (2 × f32,
##     ms); draw calls, objects, nodes, orphan nodes, memory in KB (5 × u32); then its scopes: count (u16), and for each: the name's
##     number (u16), microseconds (u32), calls (u16)
##   then the events, as every event channel (ReplayEventChannel): "scope_name" (data: number, name) the first time a name is used;
##   "log" (data: level, text, count) for warnings and errors; "capture" (data: folder) when a capture was taken (F12).
##
## Recording, from whatever measures frames:
##   channel.add_frame(record)     record: {frame, frame_ms, physics_ms, scripts_ms, rest_ms, steps, render_cpu_ms, render_gpu_ms,
##                                         draw_calls, objects, nodes, orphans, memory_kb, scopes: {name: [microseconds, calls]}}
##   channel.add_event("log", 0, {level, text, count})
## Reading: state["frames"] holds this tick's frames, as records like the above (scopes by name).
class_name ReplayDiagnosticsChannel
extends ReplayEventChannel

const ID := 6
## Frames kept waiting while no tick runs (a paused game), so a long pause doesn't fill memory. The oldest go first.
const MAX_WAITING_FRAMES := 600

var _frames: Array = [] # records waiting for the next tick
var _name_numbers := {} # scope name -> its number in this recording


func _init() -> void:
	channel_id = ID
	channel_name = "diagnostics"
	version = 1


func begin(for_recorder: ReplayRecorder) -> void:
	super(for_recorder)
	_frames.clear()
	_name_numbers.clear()


func end() -> void:
	_frames.clear()
	super()


## A finished frame's numbers, written with the next tick. Does nothing while not recording.
func add_frame(record: Dictionary) -> void:
	if recorder == null:
		return
	_frames.append(record)
	if _frames.size() > MAX_WAITING_FRAMES:
		_frames.pop_front()


func snapshot() -> Dictionary:
	var names := {}
	for name: StringName in _name_numbers:
		names[_name_numbers[name]] = String(name)
	return {"names": names}


func write_tick(tick: int, out: StreamPeerBuffer, keyframe: bool) -> void:
	# The frames first, numbering new scope names as events (written below, by super), so a reader knows each name before the next
	# tick. The snapshot on a keyframe has every name, so the frames of that tick are readable even from a block's start.
	var frames := _frames
	_frames = []
	var body := StreamPeerBuffer.new()
	body.put_u16(frames.size())
	for record: Dictionary in frames:
		body.put_u32(int(record.get("frame", 0)))
		for key in ["frame_ms", "physics_ms", "scripts_ms", "rest_ms"]:
			body.put_float(float(record.get(key, 0.0)))
		body.put_u8(clampi(int(record.get("steps", 0)), 0, 255))
		body.put_float(float(record.get("render_cpu_ms", 0.0)))
		body.put_float(float(record.get("render_gpu_ms", 0.0)))
		for key in ["draw_calls", "objects", "nodes", "orphans", "memory_kb"]:
			body.put_u32(clampi(int(record.get(key, 0)), 0, 0xFFFFFFFF))
		var scopes: Dictionary = record.get("scopes", {})
		body.put_u16(scopes.size())
		for name: StringName in scopes:
			if not _name_numbers.has(name):
				_name_numbers[name] = _name_numbers.size()
				add_event("scope_name", 0, {"number": _name_numbers[name], "name": String(name)})
			var entry: Array = scopes[name]
			body.put_u16(_name_numbers[name])
			body.put_u32(clampi(int(entry[0]), 0, 0xFFFFFFFF))
			body.put_u16(clampi(int(entry[1]), 0, 0xFFFF))
	if keyframe:
		out.put_var(snapshot())
	out.put_data(body.data_array)
	# The events, without a second snapshot: the base class writes one on a keyframe, so it's told this isn't one.
	super(tick, out, false)


func read_tick(tick: int, data: StreamPeerBuffer, keyframe: bool, state: Dictionary) -> void:
	if keyframe:
		var shot: Variant = data.get_var()
		var names := {}
		if shot is Dictionary:
			for number: int in shot.get("names", {}):
				names[number] = shot.names[number]
		state["names"] = names
	elif not state.has("names"):
		state["names"] = {}
	# The frames are read after this tick's events, because a name first used this tick arrives as an event after them. So the
	# frame bytes are kept, the events read, then the frames decoded.
	var count := data.get_u16()
	var raw_frames: Array = []
	for i in count:
		var record := {"frame": data.get_u32(), "frame_ms": data.get_float(), "physics_ms": data.get_float(),
			"scripts_ms": data.get_float(), "rest_ms": data.get_float(), "steps": data.get_u8(), "render_cpu_ms": data.get_float(),
			"render_gpu_ms": data.get_float(), "draw_calls": data.get_u32(), "objects": data.get_u32(), "nodes": data.get_u32(),
			"orphans": data.get_u32(), "memory_kb": data.get_u32()}
		var scope_count := data.get_u16()
		var numbered: Array = []
		for j in scope_count:
			numbered.append([data.get_u16(), data.get_u32(), data.get_u16()])
		record["numbered"] = numbered
		raw_frames.append(record)
	super(tick, data, false, state) # the events, which add any new names to state.names
	for record: Dictionary in raw_frames:
		var scopes := {}
		for entry: Array in record.numbered:
			scopes[state.names.get(entry[0], "#%d" % entry[0])] = [entry[1], entry[2]]
		record.erase("numbered")
		record["scopes"] = scopes
	state["frames"] = raw_frames


func apply_event(event: Dictionary, state: Dictionary) -> void:
	if event.kind == "scope_name":
		if not state.has("names"):
			state["names"] = {}
		state.names[int(event.data.get("number", -1))] = String(event.data.get("name", ""))
