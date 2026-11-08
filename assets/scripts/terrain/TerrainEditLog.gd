## Written by Claude (claude-opus-5-5), 2026-11-07: remembers every edit to a TerrainGenerator, so that a chunk built later still has them.
## An optional module: add it as a child of the TerrainGenerator, and edits survive unloading.
##
## Without it, the ground goes back to how it was generated whenever a chunk unloads. If this node is deleted while the game
## runs, or its saved data won't load, the world simply goes back to its default state. Nothing else depends on it.
##
## How it works: it stores the edits themselves, not the heights they produce. Each one is a center, radius, amount and tick,
## about 24 bytes. When a chunk is built, its edits are applied in the order they happened. Each edit is listed under every
## chunk it touches, including unloaded ones, so two chunks that share a border always agree on it.
##
## In multiplayer, the server's log is the one that counts. Clients get each edit as soon as it reaches them, which is after
## the server has applied it, by about half their ping. Prediction can differ for that moment, and normal corrections fix it.
## A late joiner gets the whole log. Both use the same bytes as to_bytes, which will suit save files too.
##
## Claude 2026-11-09, saving (pawn spec step 11): save_to_file() and load_from_file() keep the log in a file, as a 4-byte "PBTE"
## header and then to_bytes(). Saving writes a temporary file and renames it over the old one, so a crash mid-save never leaves a
## broken save: at worst the temporary file is left, and loading falls back to it. For designers, three settings do it with no code:
## save_path (empty: no file), load_on_start, and save_every_seconds (0: only when the log leaves the tree, such as on quit). Only
## the server or an offline game saves and loads: in multiplayer the server's log is the one that counts, and clients get it over
## the network.
##
## What happens in odd cases (all checked in tests/terrain_edit_selftest.gd):
##   - from_bytes given broken data: it's refused, and the log stays as it was.
##   - from_bytes given data from a terrain with different settings: it's refused, because those edits were meant for other
##     ground. The world stays as it is.
##   - The parent isn't a TerrainGenerator: it warns and does nothing.
##   - A chunk with a very long list costs more to build. Nothing merges old edits yet.
##   - Claude 2026-11-09: a save file that's missing, broken, or made for a terrain with different settings is refused, and the log
##     and the ground stay as they were. Loading or saving on a client does nothing.
class_name TerrainEditLog
extends Node

const FORMAT_VERSION := 1
# Each edit is five values: x, z, radius, amount and tick. The first four are 32-bit floats in the bytes, so every machine
# reads back the very same numbers. TerrainGenerator applies what comes back from here, even on the machine that made the edit.
const BYTES_PER_EDIT := 20
# The first byte of what goes over the network.
const MESSAGE_ONE_EDIT := 1
const MESSAGE_WHOLE_LOG := 2
# Claude 2026-11-09: the first four bytes of a save file, so a wrong file is refused before anything else is read.
const FILE_HEADER := "PBTE"

## Claude 2026-11-09: where edits are saved, such as "user://world_edits.tedits". Empty: no file.
@export var save_path := ""
## Claude 2026-11-09: on, the edits in save_path are loaded when this log enters the tree (on the server or offline).
@export var load_on_start := true
## Claude 2026-11-09: also save every this many seconds while running. 0: only when the log leaves the tree, such as on quit.
@export_range(0.0, 3600.0, 1.0, "or_greater") var save_every_seconds := 0.0

var _x := PackedFloat32Array()
var _z := PackedFloat32Array()
var _radius := PackedFloat32Array()
var _amount := PackedFloat32Array()
var _tick := PackedInt32Array()
var _by_chunk := {} # Vector2i -> PackedInt32Array of positions in the lists above, oldest first
var _terrain: TerrainGenerator = null
var _session: Node = null
var _channel := ""
var _warned_about_client_edit := false
var _since_save := 0.0 # Claude 2026-11-09: seconds since the last timed save


func _enter_tree() -> void:
	_terrain = get_parent() as TerrainGenerator
	if _terrain == null:
		push_warning("TerrainEditLog: its parent isn't a TerrainGenerator, so it does nothing.")
		return
	_terrain._edit_log_arrived(self)
	_session = get_node_or_null("/root/NetworkSession")
	if _session:
		# The path is the same on every machine, so this names the same terrain everywhere.
		_channel = "terrain_edits:%s" % _terrain.get_path()
		_session.register_world_channel(_channel, _on_network_message, _catch_up_message)
	# Claude 2026-11-09: saving. Only timed saves need a per-frame check; saving isn't game state, so it runs on frames, not ticks.
	set_process(save_every_seconds > 0.0)
	if save_path != "" and load_on_start and _may_use_files() and _save_exists(save_path):
		load_from_file(save_path)


func _exit_tree() -> void:
	# Claude 2026-11-09: save on the way out, while the terrain is still here.
	if save_path != "" and _terrain != null and _may_use_files():
		save_to_file(save_path)
	if _session and _channel != "":
		_session.unregister_world_channel(_channel)
	_channel = ""
	if _terrain != null:
		_terrain._edit_log_left(self)


## Claude 2026-11-09: saves the log to a file: a temporary file first, then renamed over the old one. OK, or why not. Does nothing
## on a client.
func save_to_file(path: String = save_path) -> Error:
	if path == "" or not _may_use_files():
		return ERR_UNAVAILABLE
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(FILE_HEADER.to_ascii_buffer())
	file.store_buffer(to_bytes())
	file.close()
	# GDScript note: DirAccess works on absolute paths; globalize_path turns "user://..." into the real folder on this computer.
	var final_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(final_path)
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), final_path)


## Claude 2026-11-09: replaces the log with the one saved in a file, and rebuilds whatever changes. If the file is missing, its
## temporary file from an interrupted save is used. False, with the log and the ground as they were, when there's no file, it's
## broken, it was made for a terrain with different settings, or this is a client.
func load_from_file(path: String = save_path) -> bool:
	if path == "" or not _may_use_files():
		return false
	var source := path if FileAccess.file_exists(path) else path + ".tmp"
	if not FileAccess.file_exists(source):
		return false
	var bytes := FileAccess.get_file_as_bytes(source)
	if bytes.size() < 4 or bytes.slice(0, 4).get_string_from_ascii() != FILE_HEADER:
		push_warning("TerrainEditLog: %s isn't a terrain edits file, so it was ignored." % source)
		return false
	return from_bytes(bytes.slice(4))


func _process(delta: float) -> void:
	# Claude 2026-11-09: timed saves. Only runs when save_every_seconds is above 0.
	_since_save += delta
	if save_every_seconds > 0.0 and _since_save >= save_every_seconds:
		_since_save = 0.0
		save_to_file(save_path)


## How many edits there are.
func get_edit_count() -> int:
	return _x.size()


## How many edits touch this chunk.
func get_chunk_edit_count(key: Vector2i) -> int:
	var list: PackedInt32Array = _by_chunk.get(key, PackedInt32Array())
	return list.size()


## Forgets every edit. Doesn't change any ground that's already built, so TerrainGenerator.generate() does this before it rebuilds.
func clear() -> void:
	_x.clear()
	_z.clear()
	_radius.clear()
	_amount.clear()
	_tick.clear()
	_by_chunk.clear()


# Claude 2026-11-09: saving and loading belong to the server, or an offline game.
func _may_use_files() -> bool:
	return _session == null or not _session.is_client()


static func _save_exists(path: String) -> bool:
	return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".tmp")


## Claude 2026-11-07: true if this machine mustn't edit the ground. Every machine has to end up with the same ground, so in multiplayer
## only the server edits, and this tells everyone.
func refuses_edit() -> bool:
	if _session == null or not _session.is_client():
		return false
	if not _warned_about_client_edit:
		_warned_about_client_edit = true
		push_warning("TerrainEditLog: a client can't edit the ground. Ask the server to. Shown once.")
	return true


## Adds an edit, positioned relative to the terrain, and returns its position in the log.
func record(x: float, z: float, radius: float, amount: float) -> int:
	var index := _add(x, z, radius, amount, _current_tick())
	if _session and _session.is_server():
		var bytes := edit_as_bytes(index)
		bytes.insert(0, MESSAGE_ONE_EDIT)
		_session.send_world_message(_channel, bytes)
	return index


## Adds this chunk's edits to a freshly generated set of points.
func apply_to_chunk(key: Vector2i, points: PackedVector3Array) -> void:
	apply_some_to_chunk(key, points, 0, get_chunk_edit_count(key))


## Adds up to count of this chunk's edits, starting at from, and returns where to carry on from.
func apply_some_to_chunk(key: Vector2i, points: PackedVector3Array, from: int, count: int) -> int:
	var list: PackedInt32Array = _by_chunk.get(key, PackedInt32Array())
	var end := mini(from + count, list.size())
	for i in range(from, end):
		var index := list[i]
		TerrainGenerator.apply_edit_to_points(points, _x[index], _z[index], _radius[index], _amount[index])
	return end


## The same for a single point, which is what smooth lighting needs at the edge of an unbuilt chunk.
func apply_to_point(key: Vector2i, point: Vector3) -> Vector3:
	var list: PackedInt32Array = _by_chunk.get(key, PackedInt32Array())
	if list.is_empty():
		return point
	var one := PackedVector3Array([point])
	for index in list:
		TerrainGenerator.apply_edit_to_points(one, _x[index], _z[index], _radius[index], _amount[index])
	return one[0]


## One edit, as bytes to send to another machine.
func edit_as_bytes(index: int) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	_write_edit(buffer, index)
	return buffer.data_array


## Adds an edit that came from edit_as_bytes on another machine. Returns its position in the log, or -1 if it's broken.
func record_from_bytes(bytes: PackedByteArray) -> int:
	if bytes.size() != BYTES_PER_EDIT:
		return -1
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	return _read_edit(buffer)


## The whole log, for a late joiner or a save file.
func to_bytes() -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.put_u8(FORMAT_VERSION)
	buffer.put_32(_settings_check())
	buffer.put_u32(_x.size())
	for index in _x.size():
		_write_edit(buffer, index)
	return buffer.data_array


## Replaces the log with one from to_bytes, and has the terrain rebuild whatever changes. False means it was refused, and the
## log and the ground are as they were.
func from_bytes(bytes: PackedByteArray) -> bool:
	if bytes.size() < 9:
		return false
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	if buffer.get_u8() != FORMAT_VERSION:
		return false
	if buffer.get_32() != _settings_check():
		push_warning("TerrainEditLog: these edits were made for a terrain with different settings, so they were ignored.")
		return false
	var count := buffer.get_u32()
	if bytes.size() != 9 + count * BYTES_PER_EDIT:
		return false
	# Claude 2026-11-07, from the audit of 6df1464: every record is checked before anything changes. This used to clear the log first,
	# so one bad record left it empty while the built ground still had the old edits.
	var incoming: Array[PackedFloat32Array] = []
	var ticks := PackedInt32Array()
	for i in count:
		var x := buffer.get_float()
		var z := buffer.get_float()
		var radius := buffer.get_float()
		var amount := buffer.get_float()
		var tick := buffer.get_32()
		if not _is_valid_edit(x, z, radius, amount):
			return false
		incoming.append(PackedFloat32Array([x, z, radius, amount]))
		ticks.append(tick)
	# All good: now it's replaced. Half-built chunks finish first, with the old log, and are rebuilt below like the others.
	if _terrain != null:
		_terrain._finish_building_chunks()
	var chunks_before: Array = _by_chunk.keys()
	clear()
	for i in incoming.size():
		_add(incoming[i][0], incoming[i][1], incoming[i][2], incoming[i][3], ticks[i])
	if _terrain != null:
		_terrain._rebuild_chunks_for_log(chunks_before + _by_chunk.keys())
	return true


# --- Multiplayer ---


## Client: something arrived from the server's log.
func _on_network_message(bytes: PackedByteArray) -> void:
	if bytes.is_empty() or _terrain == null or _session == null or not _session.is_client():
		return
	var body := bytes.slice(1)
	if bytes[0] == MESSAGE_ONE_EDIT:
		_receive_edit(body) # Claude 2026-11-07: split out, so a test can call it without a network
	elif bytes[0] == MESSAGE_WHOLE_LOG and from_bytes(body):
		# A joining pawn may be about to take its first tick here, so this can't wait for later frames.
		_terrain.finish_rebuilds()


## Claude 2026-11-07, from the audit of 6df1464: one edit from the server, applied exactly once. Half-built chunks are finished
## before the edit is recorded, the same order edit() uses on the server. Recording first made a half-built chunk read the edit
## from the log while finishing, then get it again from the loaded-chunk pass. Returns its position in the log, or -1 if broken.
func _receive_edit(bytes: PackedByteArray) -> int:
	if _terrain == null or bytes.size() != BYTES_PER_EDIT:
		return -1
	_terrain._finish_building_chunks()
	var index := record_from_bytes(bytes)
	if index >= 0:
		_terrain._apply_edit_from_log(_x[index], _z[index], _radius[index], _amount[index])
	return index


## Server: what a late joiner needs. Empty means nothing to send.
func _catch_up_message() -> PackedByteArray:
	if _x.is_empty():
		return PackedByteArray()
	var bytes := to_bytes()
	bytes.insert(0, MESSAGE_WHOLE_LOG)
	return bytes


func _write_edit(buffer: StreamPeerBuffer, index: int) -> void:
	buffer.put_float(_x[index])
	buffer.put_float(_z[index])
	buffer.put_float(_radius[index])
	buffer.put_float(_amount[index])
	buffer.put_32(_tick[index])


func _read_edit(buffer: StreamPeerBuffer) -> int:
	var x := buffer.get_float()
	var z := buffer.get_float()
	var radius := buffer.get_float()
	var amount := buffer.get_float()
	var tick := buffer.get_32()
	if not _is_valid_edit(x, z, radius, amount):
		return -1
	return _add(x, z, radius, amount, tick)


## Claude 2026-11-07: the one check every edit from outside has to pass. Shared by single edits and whole logs.
func _is_valid_edit(x: float, z: float, radius: float, amount: float) -> bool:
	return is_finite(x) and is_finite(z) and is_finite(radius) and is_finite(amount) and radius > 0.0


func _add(x: float, z: float, radius: float, amount: float, tick: int) -> int:
	var index := _x.size()
	_x.append(x)
	_z.append(z)
	_radius.append(radius)
	_amount.append(amount)
	_tick.append(tick)
	if _terrain != null:
		for key in _terrain.chunks_touched_by_edit(x, z, radius):
			# GDScript note: a packed array in a Dictionary has to be stored back after changing it, to be sure it sticks.
			var list: PackedInt32Array = _by_chunk.get(key, PackedInt32Array())
			list.append(index)
			_by_chunk[key] = list
	return index


## The current tick, for the records. It's only informative, so 0 is fine with no tick driver.
func _current_tick() -> int:
	var driver: Node = get_node_or_null("/root/TickDriver") if is_inside_tree() else null
	return driver.tick if driver else 0


## A number that changes if the settings that decide the ground change.
func _settings_check() -> int:
	if _terrain == null:
		return 0
	return _terrain.ground_settings_hash() & 0x7FFFFFFF
