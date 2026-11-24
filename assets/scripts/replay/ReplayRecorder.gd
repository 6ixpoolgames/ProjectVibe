# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## Records every pawn, every tick, to a replay file.
##
## A GameMode module ([code]GameMode.replay_recorder[/code]) that records nothing until [method start_recording] is called when play
## starts (the samples do; [DiagnosticsManager] does if none is running). Once a tick ([signal TickDriver.after_tick], which never
## fires during a rollback replay) it gives new pawns a replay id and has each channel write its bytes into the current block; every
## [member block_seconds] the block, opening with a keyframe, goes to the [ReplayWriter]. A game adds its own channels with
## [method add_channel] before recording starts.
## [br]
## Files: [code]<folder>/<role>/<date>_<time>.pbreplay[/code], role "host" (also offline) or "client"; a run with no display uses
## [code]<folder>/headless/<role>[/code]. Only the newest [member keep_recordings] per folder are kept.
## [br]
## Safeguards stop a recording with a warning ([method get_stopped_reason]) and leave the file readable: length, file size, free
## disk space, folder size, and the writer falling behind or failing. Each limit is a setting below; 0 switches it off.
## Design: replay spec 3 and 3.1.
class_name ReplayRecorder
extends GameModeModule

## Sent when a recording starts, with the file's path.
signal recording_started(path: String)
## Sent when a recording stops, with the file's path.
signal recording_stopped(path: String)

const FILE_EXTENSION := "pbreplay"
## The first bytes of every replay file.
const MAGIC := "PBRP"
## Raised when the file's layout changes (replay spec 2); channels have their own versions.
const FORMAT_VERSION := 1
## Ids given to pawns that aren't networked start here, well above any entity id.
const LOCAL_IDS_START := 1 << 30

## Off: [method start_recording] does nothing.
@export var enabled := true
## Where recordings go. Each role gets a folder of its own inside it.
@export var folder := "user://replays"
## On, a run with no display (a test, a dedicated server) records into folder/headless/<role> instead, with its own [member keep_recordings].
@export var headless_runs_apart := true
## Recordings kept per role's folder; older ones are deleted when a new one starts. 0 keeps all, and skips [member max_folder_megabytes] too.
@export_range(0, 1000, 1, "or_greater") var keep_recordings := 100
## Block length in seconds. Seeking starts at a block's keyframe: shorter seeks faster, longer makes smaller files.
@export_range(0.1, 10.0, 0.1) var block_seconds := 1.0
## The longest a recording may be, in seconds (3 hours). 0 switches it off, as for the other safeguards below.
@export_range(0.0, 86400.0, 60.0, "or_greater") var max_recording_seconds := 10800.0
## The biggest a recording's file may get, in megabytes (2 GB).
@export_range(0, 100000, 1, "or_greater") var max_file_megabytes := 2048
## The least free disk space recording needs, in megabytes (1 GB). Checked at the start and every minute.
@export_range(0, 100000, 1, "or_greater") var min_free_megabytes := 1024
## The most a role's folder may hold, in megabytes (4 GB); oldest recordings are deleted to stay under it, never the one being written.
@export_range(0, 1000000, 1, "or_greater") var max_folder_megabytes := 4096
## How many finished blocks may wait for the writer before the recording stops: with 1 s blocks, the seconds the disk may fall behind.
@export_range(1, 3600, 1, "or_greater") var max_queued_blocks := 60

var _channels: Array[ReplayChannel] = []
var _recording := false
var _path := ""
var _writer: ReplayWriter = null
var _driver: Node = null
var _ids := {} # pawn instance id -> replay id
var _arrived: Array = [] # pawns that entered the tree since last tick, handed to the channels at the next tick
var _next_local_id := LOCAL_IDS_START
var _block: Array[StreamPeerBuffer] = [] # one buffer per channel, in the order of _channels
var _block_first_tick := -1
var _block_ticks := 0
var _ticks_recorded := 0
var _last_tick_recorded := -1 # only ticks after this are recorded (see _record_tick)
var _stopped_reason := "" # why the last recording stopped, if a safeguard stopped it
var _next_space_check_msec := 0



## The settings a start menu may offer (GameModeModule.get_match_options): whether this match is recorded.
func get_match_options() -> PackedStringArray:
	return PackedStringArray(["enabled"])


func _init() -> void:
	set_process(false)
	set_physics_process(false)
	# The base's channels; diagnostics (6) is added by DiagnosticsManager when the game has it.
	# REFACTOR: the same list of base channels as ReplayReader._init, written out twice. One list on ReplayChannel is one place to add
	# a channel. Extensible. See CHANGELOG.md.
	for channel: ReplayChannel in [ReplayMotionChannel.new(), ReplayInputChannel.new(), ReplaySpawnChannel.new(),
			ReplayWorldChannel.new(), ReplayGameplayChannel.new()]:
		_channels.append(channel)


func _on_module_added(game_mode: GameModeSingleton) -> void:
	game_mode.replay_recorder = self
	_driver = get_node_or_null("/root/TickDriver")


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	stop_recording()
	game_mode.replay_recorder = null


func _exit_tree() -> void:
	stop_recording() # the game is closing: finish the file and stop the writer's thread


## Adds a channel before recording starts. Its id must be unused: 1 to 99 are the base's (6 is diagnostics), a game's own use 100+.
func add_channel(channel: ReplayChannel) -> void:
	if _recording:
		push_warning("ReplayRecorder: add_channel() while recording does nothing; add it before start_recording().")
		return
	for existing in _channels:
		if existing.channel_id == channel.channel_id:
			push_warning("ReplayRecorder: a channel with id %d is already there (%s)." % [channel.channel_id, existing.channel_name])
			return
	_channels.append(channel)


## The channels, in the order they're written.
func get_channels() -> Array[ReplayChannel]:
	return _channels


## Starts recording to a new file, after stopping any running one. [code]role[/code] ("host", also offline, or "client") picks the folder. Returns the error if the file can't be made.
func start_recording(role: String) -> Error:
	stop_recording()
	if not enabled or _driver == null:
		return ERR_UNAVAILABLE
	var role_folder := _role_folder(role) # headless runs apart (headless_runs_apart)
	var made := DirAccess.make_dir_recursive_absolute(role_folder)
	if made != OK:
		push_warning("ReplayRecorder: couldn't make %s (error %d), so nothing is recorded." % [role_folder, made])
		return made
	# Refuses to start without room on the disk.
	var space := _free_megabytes(role_folder)
	if min_free_megabytes > 0 and space >= 0 and space < min_free_megabytes:
		push_warning("ReplayRecorder: only %d MB free, under min_free_megabytes (%d), so nothing is recorded." % [space, min_free_megabytes])
		_stopped_reason = "not enough disk space"
		return ERR_FILE_NO_PERMISSION
	_prune(role_folder, keep_recordings - 1) # room for the new one
	# File-name-friendly date and time.
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	_path = role_folder.path_join("%s.%s" % [stamp, FILE_EXTENSION])
	var suffix := 2
	while FileAccess.file_exists(_path): # two recordings started in the same second
		_path = role_folder.path_join("%s_%d.%s" % [stamp, suffix, FILE_EXTENSION])
		suffix += 1
	_writer = ReplayWriter.new()
	_writer.max_queued_blocks = max_queued_blocks
	var error := _writer.open(_path, _header(role))
	if error != OK:
		push_warning("ReplayRecorder: couldn't create %s (error %d), so nothing is recorded." % [_path, error])
		_writer = null
		return error
	_recording = true
	_stopped_reason = ""
	_next_space_check_msec = Time.get_ticks_msec() + 60000
	_ids.clear()
	_arrived.clear()
	_next_local_id = LOCAL_IDS_START
	_ticks_recorded = 0
	_last_tick_recorded = -1
	_start_block()
	for channel in _channels:
		channel.begin(self)
	# Pawns already here are handed over at the first tick, like any that arrive later.
	for node in get_tree().get_nodes_in_group(Pawn.GROUP): # every pawn already here when the recording starts
		if node is Pawn:
			_arrived.append(node)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	_driver.after_tick.connect(_on_after_tick)
	recording_started.emit(_path)
	return OK


## Stops recording: writes the block so far, closes the file and stops the writer's thread.
func stop_recording() -> void:
	if not _recording:
		return
	_recording = false
	if _driver and _driver.after_tick.is_connected(_on_after_tick):
		_driver.after_tick.disconnect(_on_after_tick)
	if is_inside_tree():
		if get_tree().node_added.is_connected(_on_node_added):
			get_tree().node_added.disconnect(_on_node_added)
		if get_tree().node_removed.is_connected(_on_node_removed):
			get_tree().node_removed.disconnect(_on_node_removed)
	_finish_block()
	for channel in _channels:
		channel.end()
	_writer.close()
	if _writer.get_error() != OK:
		push_warning("ReplayRecorder: writing %s failed (error %d); the file may stop early." % [_path, _writer.get_error()])
	_writer = null
	_ids.clear()
	_arrived.clear()
	recording_stopped.emit(_path)


## True while a recording is running.
func is_recording() -> bool:
	return _recording


## Why a safeguard stopped the last recording, or "" if [method stop_recording] did or it is still running.
func get_stopped_reason() -> String:
	return _stopped_reason


## The file being recorded, or the last one recorded.
func get_recording_path() -> String:
	return _path


## How many ticks this recording holds so far.
func get_ticks_recorded() -> int:
	return _ticks_recorded


## The file's size so far, in bytes (as of the last block written).
func get_bytes_written() -> int:
	return _writer.get_bytes_written() if _writer else 0


## A pawn's id in the recording: its NetworkEntity id where it has one (the same on every machine), else one handed out here. 0 for none.
func get_replay_id(node: Node) -> int:
	if not is_instance_valid(node):
		return 0
	return _ids.get(node.get_instance_id(), 0)


# --- Each tick ---


func _on_after_tick(_dt: float, tick: int) -> void:
	var started := PerfScopes.begin() # timed for diagnostics, as "replay.record"
	_record_tick(tick)
	PerfScopes.end(&"replay.record", started)


# The work itself, timed by _on_after_tick.
func _record_tick(tick: int) -> void:
	# Ticks must only go up, because the reader finds frames by tick: a client's clock jumping back (a resync) is skipped until it passes.
	if tick <= _last_tick_recorded:
		return
	_last_tick_recorded = tick
	_hand_over_arrivals()
	if _block_first_tick < 0:
		_block_first_tick = tick
	var keyframe := _block_ticks == 0
	for i in _channels.size():
		var out := _block[i]
		# A tick's part: its number, its byte count (filled in after), then the channel's bytes.
		out.put_u32(tick)
		var size_at := out.get_position()
		out.put_u32(0)
		_channels[i].write_tick(tick, out, keyframe)
		var end_at := out.get_position()
		out.seek(size_at)
		out.put_u32(end_at - size_at - 4)
		out.seek(end_at)
	_block_ticks += 1
	_ticks_recorded += 1
	var ticks_per_block := maxi(1, roundi(block_seconds * _driver.get_tick_rate()))
	if _block_ticks >= ticks_per_block:
		_finish_block()
		_start_block()


func _hand_over_arrivals() -> void:
	if _arrived.is_empty():
		return
	var arrived := _arrived
	_arrived = []
	# The loop variable is a Variant: a freed pawn can't go in a Pawn-typed variable.
	for node: Variant in arrived:
		# Checked again: it may have left the tree, or been freed, since it arrived.
		if not is_instance_valid(node) or not (node as Pawn).is_inside_tree() or _ids.has((node as Pawn).get_instance_id()):
			continue
		var pawn: Pawn = node
		var entity := pawn.get_network_entity()
		var id: int
		if entity and entity.entity_id >= 0:
			id = entity.entity_id
		else:
			id = _next_local_id
			_next_local_id += 1
		_ids[pawn.get_instance_id()] = id
		for channel in _channels:
			channel.pawn_added(pawn, id)


# Handed over at the next tick rather than now, because a pawn entering the tree hasn't found its parts yet (Pawn._ready runs after).
func _on_node_added(node: Node) -> void:
	if node is Pawn:
		_arrived.append(node)


func _on_node_removed(node: Node) -> void:
	if not (node is Pawn):
		return
	_arrived.erase(node)
	var key := node.get_instance_id()
	if not _ids.has(key):
		return
	var id: int = _ids[key]
	_ids.erase(key)
	for channel in _channels:
		channel.pawn_removed(node, id)


# --- Blocks and the file ---


func _start_block() -> void:
	_block.clear()
	for channel in _channels:
		var buffer := StreamPeerBuffer.new() # little-endian, as the whole file is
		_block.append(buffer)
	_block_first_tick = -1
	_block_ticks = 0


# A block (replay spec 2): first tick (u32), tick count (u16), channel count (u16), then per channel its id (u16), byte count (u32)
# and bytes. The writer compresses it.
func _finish_block() -> void:
	if _block_ticks == 0 or _writer == null:
		return
	var out := StreamPeerBuffer.new()
	out.put_u32(_block_first_tick)
	out.put_u16(_block_ticks)
	out.put_u16(_channels.size())
	for i in _channels.size():
		var bytes := _block[i].data_array
		out.put_u16(_channels[i].channel_id)
		out.put_u32(bytes.size())
		out.put_data(bytes)
	# The writer refuses a block when too many are already waiting, or after a write failed.
	if not _writer.push_block(out.data_array):
		_safeguard_stop.call_deferred("the writer fell %d blocks behind or failed to write (error %d)" % [max_queued_blocks, _writer.get_error()])
	_block_ticks = 0
	_check_limits()


# The safeguards checked once a block (see the top of the file). Stopping is deferred to the end of the frame,
# because this runs inside the tick's after_tick signal.
func _check_limits() -> void:
	if not _recording or _writer == null:
		return
	if max_recording_seconds > 0.0 and _ticks_recorded >= roundi(max_recording_seconds * _driver.get_tick_rate()):
		_safeguard_stop.call_deferred("it reached max_recording_seconds (%.0f s)" % max_recording_seconds)
	elif max_file_megabytes > 0 and _writer.get_bytes_written() >= max_file_megabytes * 1048576:
		_safeguard_stop.call_deferred("its file reached max_file_megabytes (%d MB)" % max_file_megabytes)
	elif min_free_megabytes > 0 and Time.get_ticks_msec() >= _next_space_check_msec:
		_next_space_check_msec = Time.get_ticks_msec() + 60000
		var space := _free_megabytes(_path.get_base_dir())
		if space >= 0 and space < min_free_megabytes:
			_safeguard_stop.call_deferred("the disk has only %d MB free (min_free_megabytes %d)" % [space, min_free_megabytes])


func _safeguard_stop(reason: String) -> void:
	if not _recording:
		return
	push_warning("ReplayRecorder: stopped recording %s, because %s. The file is complete up to there." % [_path, reason])
	stop_recording()
	_stopped_reason = reason


# Free space on the disk holding a folder, in megabytes, or -1 if it can't be found out.
static func _free_megabytes(in_folder: String) -> int:
	var dir := DirAccess.open(in_folder)
	return int(dir.get_space_left() / 1048576.0) if dir else -1


# The header (replay spec 2): magic, format version (u16), the fields' byte count (u32), then the fields as one Dictionary (var_to_bytes).
func _header(role: String) -> PackedByteArray:
	var channels: Array = []
	for channel in _channels:
		channels.append({"id": channel.channel_id, "name": channel.channel_name, "version": channel.version})
	var fields := {
		"tick_rate": _driver.get_tick_rate(),
		"first_tick": _driver.tick,
		"role": role,
		"started": Time.get_datetime_string_from_system(false, true),
		"game": "%s %s" % [ProjectSettings.get_setting("application/config/name", ""), ProjectSettings.get_setting("application/config/version", "")],
		"block_seconds": block_seconds,
		"channels": channels,
	}
	var body := var_to_bytes(fields)
	var out := StreamPeerBuffer.new()
	out.put_data(MAGIC.to_ascii_buffer())
	out.put_u16(FORMAT_VERSION)
	out.put_u32(body.size())
	out.put_data(body)
	return out.data_array


# The folder a role's recordings go in: folder/<role>, or folder/headless/<role> for a run with no display.
func _role_folder(role: String) -> String:
	if headless_runs_apart and RunEnvironment.is_headless():
		return folder.path_join("headless").path_join(role)
	return folder.path_join(role)


# Deletes the oldest recordings until at most keep are left. Names start with the date and time, so name order is age order.
func _prune(role_folder: String, keep: int) -> void:
	if keep_recordings <= 0:
		return # keeping them all, which skips the folder size limit too
	var names: Array[String] = []
	for file_name in DirAccess.get_files_at(role_folder):
		if file_name.get_extension() == FILE_EXTENSION:
			names.append(file_name)
	names.sort()
	# Also down to max_folder_megabytes, oldest first, never the file being recorded; one another instance has open can't be deleted
	# (Windows refuses) and is skipped.
	var sizes := {}
	var total := 0
	for file_name in names:
		var file := FileAccess.open(role_folder.path_join(file_name), FileAccess.READ)
		sizes[file_name] = file.get_length() if file else 0
		total += sizes[file_name]
	var limit := max_folder_megabytes * 1048576 if max_folder_megabytes > 0 else -1
	for file_name in names.duplicate():
		var too_many := names.size() > maxi(keep, 0)
		var too_big := limit >= 0 and total >= limit # under the limit, not at it
		if not too_many and not too_big:
			break
		var path := role_folder.path_join(file_name)
		if path == _path and _recording:
			continue
		if DirAccess.remove_absolute(path) == OK:
			names.erase(file_name)
			total -= sizes[file_name]
