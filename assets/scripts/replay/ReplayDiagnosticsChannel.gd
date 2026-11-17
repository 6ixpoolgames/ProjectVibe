# Written by Claude (claude-opus-5-5), 2026-11-16. History: replay/CHANGELOG.md.
## Replay channel 6, "diagnostics": how each frame went, recorded alongside the game.
##
## One recording then holds what happened and what it cost. The [DiagnosticsManager] adds this channel and fills it; in a game
## without it nothing is recorded here. A tick writes the frames that finished since the last tick (a frame can run two ticks, or
## none while paused), each with its own frame number.
## [br]
## A tick's bytes: on a keyframe, the snapshot (put_var: the scope names so far); the frame count (u16), then per frame: number (u32);
## frame, physics, scripts and rest ms (4 × f32); physics steps (u8); render CPU and GPU ms (2 × f32); draw calls, objects, nodes,
## orphans, memory KB (5 × u32); scopes: count (u16), then name number (u16), microseconds (u32), calls (u16); then the events.
## Events ([ReplayEventChannel]): "scope_name" (number, name), "log" (level, text, count), "capture" (folder; F12).
## [codeblock]
## channel.add_frame({frame, frame_ms, ..., scopes: {name: [microseconds, calls]}})
## [/codeblock]
## Reading: [code]state["frames"][/code] holds this tick's frames as such records. Design: diagnostics spec.
class_name ReplayDiagnosticsChannel
extends ReplayEventChannel

const ID := 6
## Most frames kept waiting while no tick runs (a paused game); the oldest go first.
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
	# New scope names become events (written by super below); a keyframe's snapshot has every name, so a block start is readable.
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
	# keyframe is false here: the snapshot is already written above.
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
	# A name first used this tick arrives as an event after the frames, so the frames are decoded after the events are read.
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
