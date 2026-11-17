# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## Reads a replay file (docs/replay/REPLAY_SPEC.md) and gives the state at any tick.
##
## The viewer uses it, and so can a test or a tool. It finds the tick's block, decodes it from its keyframe (caching the last few)
## and reads the state at that tick. A file cut short opens with everything up to its last whole block ([method is_cut_short]); a
## channel it has no class for is skipped.
## [codeblock]
## var reader := ReplayReader.new()
## if reader.open(path) == OK:
##     var frame := reader.get_frame(tick)  # tick, pawns (id -> name, scene, team, motion, input), terrains, sources, events, diagnostics
##     reader.get_events(from_tick, to_tick)
## [/codeblock]
## Design: replay spec 2.
# REFACTOR: open() reads the whole file into memory and decompresses every block once just to learn its ticks. A long recording
# (hundreds of MB an hour at mass-battle sizes) would open faster and use less memory with an index of blocks. Efficient. See CHANGELOG.md.
class_name ReplayReader
extends RefCounted

## How many decoded blocks are kept, so stepping back and forth doesn't decode one twice.
var blocks_cached := 4

var _header := {}
var _bytes := PackedByteArray()
var _blocks: Array = [] # [first tick, last tick, offset of the compressed bytes, compressed size, raw size], in file order
var _cut_short := false
var _channels := {} # channel id -> a ReplayChannel used for reading
var _cache := {} # block index -> decoded block
var _cache_order: Array[int] = []


# The base's channels, diagnostics included, so any recording made by the base reads in full.
# REFACTOR: the same list of base channels as ReplayRecorder._init, written out twice (the recorder's leaves out diagnostics). One list
# on ReplayChannel is one place to add a channel. Extensible. See CHANGELOG.md.
func _init() -> void:
	for channel: ReplayChannel in [ReplayMotionChannel.new(), ReplayInputChannel.new(), ReplaySpawnChannel.new(),
			ReplayWorldChannel.new(), ReplayGameplayChannel.new(), ReplayDiagnosticsChannel.new()]:
		_channels[channel.channel_id] = channel


## Adds a game's own channel class, so its data is read too. Before open().
func add_channel(channel: ReplayChannel) -> void:
	_channels[channel.channel_id] = channel


## Reads the file's header and finds its blocks. Returns an error if it isn't a replay file, or one this code can't read.
func open(path: String) -> Error:
	_bytes = FileAccess.get_file_as_bytes(path)
	if _bytes.is_empty():
		return FileAccess.get_open_error() if FileAccess.get_open_error() != OK else ERR_FILE_CORRUPT
	var data := StreamPeerBuffer.new()
	data.data_array = _bytes
	if _bytes.size() < 10 or _bytes.slice(0, 4).get_string_from_ascii() != ReplayRecorder.MAGIC:
		return ERR_FILE_UNRECOGNIZED
	data.seek(4)
	var format := data.get_u16()
	if format > ReplayRecorder.FORMAT_VERSION:
		return ERR_FILE_UNRECOGNIZED # newer than this code
	var header_size := data.get_u32()
	if data.get_position() + header_size > _bytes.size():
		return ERR_FILE_CORRUPT
	var fields: Variant = bytes_to_var(_bytes.slice(data.get_position(), data.get_position() + header_size))
	if not (fields is Dictionary):
		return ERR_FILE_CORRUPT
	_header = fields
	_header["format"] = format
	# Each channel class learns which of its versions the file holds, so it can read older layouts.
	for info: Variant in _header.get("channels", []):
		if info is Dictionary and _channels.has(info.get("id")):
			_channels[info.id].file_version = int(info.get("version", 1))
	var at := data.get_position() + header_size
	_blocks.clear()
	_cache.clear()
	_cache_order.clear()
	_cut_short = false
	# Each block: raw size (u32), compressed size (u32), compressed bytes. Its first tick and tick count are inside, so each block is
	# decompressed once here to read them.
	while at < _bytes.size():
		if at + 8 > _bytes.size():
			_cut_short = true
			break
		data.seek(at)
		var raw_size := data.get_u32()
		var packed_size := data.get_u32()
		if at + 8 + packed_size > _bytes.size():
			_cut_short = true
			break
		var raw := _bytes.slice(at + 8, at + 8 + packed_size).decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
		if raw.size() != raw_size or raw_size < 8:
			_cut_short = true
			break
		var inside := StreamPeerBuffer.new()
		inside.data_array = raw
		var first := inside.get_u32()
		_blocks.append([first, _last_tick_of(raw, first), at + 8, packed_size, raw_size])
		at += 8 + packed_size
	return OK


## The file's header: tick_rate, first_tick, role, started, game, block_seconds, channels, format.
func get_header() -> Dictionary:
	return _header


## True if the file ends partway through a block, as one from a game that crashed or was killed does.
func is_cut_short() -> bool:
	return _cut_short


## How many whole blocks the file holds.
func get_block_count() -> int:
	return _blocks.size()


## The first tick recorded, or -1 for an empty recording.
func get_first_tick() -> int:
	return _blocks[0][0] if not _blocks.is_empty() else -1


## The last tick recorded, or -1 for an empty recording.
func get_last_tick() -> int:
	return _blocks[-1][1] if not _blocks.is_empty() else -1


## Every tick recorded, in order. Usually every tick from first to last, but a client's ticks can jump.
func get_ticks() -> Array[int]:
	var ticks: Array[int] = []
	for i in _blocks.size():
		ticks.append_array(_decoded(i).ticks)
	return ticks


## The state at a tick: [code]{tick (the nearest recorded one at or before it), pawns, terrains, sources, events, diagnostics}[/code]. Before the first tick gives the first, after the last gives the last.
func get_frame(tick: int) -> Dictionary:
	if _blocks.is_empty():
		return {"tick": -1, "pawns": {}, "terrains": {}, "sources": {}, "events": [], "diagnostics": []}
	var index := _block_index(tick)
	var block: Dictionary = _decoded(index)
	var ticks: Array[int] = block.ticks
	var at := ticks.bsearch(tick, false) - 1 # the last recorded tick at or before the one asked for
	at = clampi(at, 0, ticks.size() - 1)
	var states: Dictionary = block.states[at] # channel id -> that channel's state at this tick
	var spawns: Dictionary = states.get(ReplaySpawnChannel.ID, {})
	var motion: Dictionary = states.get(ReplayMotionChannel.ID, {})
	var input: Dictionary = states.get(ReplayInputChannel.ID, {})
	var world: Dictionary = states.get(ReplayWorldChannel.ID, {})
	var pawns := {}
	for id: int in spawns.get("pawns", {}):
		var info: Dictionary = (spawns.pawns[id] as Dictionary).duplicate()
		info["motion"] = motion.get(id)
		info["input"] = input.get(id)
		pawns[id] = info
	return {"tick": ticks[at], "pawns": pawns, "terrains": world.get("terrains", {}), "sources": world.get("sources", {}),
		"events": block.events[at], "diagnostics": states.get(ReplayDiagnosticsChannel.ID, {}).get("frames", [])}


## Every event from from_tick to to_tick, both included, oldest first. Each is {tick, channel, kind, id, data}.
func get_events(from_tick: int, to_tick: int) -> Array:
	var out: Array = []
	if _blocks.is_empty():
		return out
	for index in range(_block_index(from_tick), _blocks.size()):
		if _blocks[index][0] > to_tick:
			break
		var block: Dictionary = _decoded(index)
		for i in block.ticks.size():
			var tick: int = block.ticks[i]
			if tick >= from_tick and tick <= to_tick:
				out.append_array(block.events[i])
	return out


## Every diagnostics frame from from_tick to to_tick, both included, as [tick, frame record], oldest first. Empty
## for a recording without the diagnostics channel.
func get_diagnostics(from_tick: int, to_tick: int) -> Array:
	var out: Array = []
	if _blocks.is_empty():
		return out
	for index in range(_block_index(from_tick), _blocks.size()):
		if _blocks[index][0] > to_tick:
			break
		var block: Dictionary = _decoded(index)
		for i in block.ticks.size():
			var tick: int = block.ticks[i]
			if tick >= from_tick and tick <= to_tick:
				for record: Dictionary in block.states[i].get(ReplayDiagnosticsChannel.ID, {}).get("frames", []):
					out.append([tick, record])
	return out


# --- Decoding ---


# The block holding a tick: the last block starting at or before it.
func _block_index(tick: int) -> int:
	var low := 0
	var high := _blocks.size() - 1
	while low < high:
		@warning_ignore("integer_division")
		var middle := (low + high + 1) / 2
		if _blocks[middle][0] <= tick:
			low = middle
		else:
			high = middle - 1
	return low


# A whole block, decoded: {ticks: Array[int], states: per tick, channel id -> state, events: per tick, Array of events}.
func _decoded(index: int) -> Dictionary:
	if _cache.has(index):
		return _cache[index]
	var entry: Array = _blocks[index]
	var raw := _bytes.slice(entry[2], entry[2] + entry[3]).decompress(entry[4], FileAccess.COMPRESSION_ZSTD)
	var data := StreamPeerBuffer.new()
	data.data_array = raw
	data.get_u32() # first tick
	var tick_count := data.get_u16()
	var channel_count := data.get_u16()
	var ticks: Array[int] = []
	var states: Array = []
	var events: Array = []
	for i in tick_count:
		states.append({})
		events.append([])
	for c in channel_count:
		var channel_id := data.get_u16()
		var size := data.get_u32()
		var end_at := data.get_position() + size
		var channel: ReplayChannel = _channels.get(channel_id)
		if channel != null:
			var state := {}
			var i := 0
			while data.get_position() < end_at and i < tick_count:
				var tick := data.get_u32()
				var tick_size := data.get_u32()
				var tick_end := data.get_position() + tick_size
				if ticks.size() <= i:
					ticks.append(tick)
				if i > 0:
					state = channel.copy_state(state)
				var tick_data := StreamPeerBuffer.new()
				tick_data.data_array = raw.slice(data.get_position(), tick_end)
				channel.read_tick(tick, tick_data, i == 0, state)
				states[i][channel_id] = state
				for event: Dictionary in state.get("events", []):
					var tagged := event.duplicate()
					tagged["channel"] = channel.channel_name
					events[i].append(tagged)
				data.seek(tick_end)
				i += 1
		data.seek(end_at) # a channel with no class here is skipped by its byte count
	var block := {"ticks": ticks, "states": states, "events": events}
	_cache[index] = block
	_cache_order.append(index)
	while _cache_order.size() > blocks_cached:
		_cache.erase(_cache_order.pop_front())
	return block


# A block's last tick, from its first channel's tick list: the ticks can jump on a client, so it isn't simply first + count - 1.
static func _last_tick_of(raw: PackedByteArray, first: int) -> int:
	var data := StreamPeerBuffer.new()
	data.data_array = raw
	data.seek(4)
	var tick_count := data.get_u16()
	var channel_count := data.get_u16()
	if channel_count == 0 or tick_count == 0:
		return first
	data.get_u16() # the first channel's id
	data.get_u32() # its byte count
	var last := first
	for i in tick_count:
		last = data.get_u32()
		var size := data.get_u32()
		data.seek(data.get_position() + size)
	return last
