## Written by Claude (claude-opus-5-5), 2026-11-15: records the game to a replay file, replay v0 (docs/replay/REPLAY_SPEC.md). A
## GameMode module, reached as GameMode.replay_recorder. It records nothing until start_recording() is called, which the game does
## when play starts: on the host when the player picks Offline or Host, and on a client once Join has connected (the samples do this).
##
## What it records: every pawn, AI ones included, every tick, through its channels (replay spec section 3):
##   motion (where each pawn is and its flags), input (its input command), spawns (who exists), world (chunks and chunk sources) and
##   gameplay (hits, deaths, abilities, AI changes, freezes, possession, falls).
## A game can add its own channels with add_channel() before recording starts.
##
## How it works, once a tick (TickDriver's after_tick, which never fires while a rollback replays ticks, so nothing is recorded twice):
##   1. Pawns that entered the tree since last tick are given a replay id and handed to every channel.
##   2. Each channel writes this tick's bytes into its part of the current block. A block's first tick is a keyframe: every channel
##      writes everything as it is, so a reader can start there.
##   3. After block_seconds of ticks, the block is finished and handed to the ReplayWriter, which compresses and writes it on its own
##      thread.
##
## Files: <folder>/<role>/<date>_<time>.pbreplay, with role "host" (host and offline) or "client". Only the newest keep_recordings in
## each folder are kept; older ones are deleted when a new recording starts.
##
## Claude 2026-11-16, safeguards (the owner asked that the writer can never run away, write more recordings than the cap, or grow one
## recording without limit). Each stops the recording with a warning saying why (get_stopped_reason), and the file stays readable:
##   - max_recording_seconds (3 hours): a recording stops when it's this long.
##   - max_file_megabytes (2 GB): a recording stops when its file is this big, whatever its length.
##   - min_free_megabytes (1 GB): a recording doesn't start, or stops, when the disk has less room than this. Checked every minute.
##   - max_folder_megabytes (4 GB): old recordings in a role's folder are deleted, oldest first, until the folder is under this, as
##     well as down to keep_recordings. The file being recorded is never deleted, and one another instance still has open can't be
##     (Windows refuses), so it's skipped.
##   - The writer's queue: if the disk falls so far behind that max_queued_blocks blocks are waiting, the recording stops rather than
##     filling memory. And if writing fails (a full disk, a lost drive), the writer stops writing and the recording stops.
class_name ReplayRecorder
extends GameModeModule

## Sent when a recording starts, with the file's path.
signal recording_started(path: String)
## Sent when a recording stops, with the file's path.
signal recording_stopped(path: String)

const FILE_EXTENSION := "pbreplay"
## The first bytes of every replay file.
const MAGIC := "PBRP"
## Raised when the file's layout changes (replay spec section 2), not when a channel changes: channels have their own versions.
const FORMAT_VERSION := 1
## Ids given to pawns that aren't networked start here, well above any entity id.
const LOCAL_IDS_START := 1 << 30

## Off: start_recording() does nothing. For a game, or a test, that doesn't want recordings.
@export var enabled := true
## Where recordings go. Each role gets a folder of its own inside it.
@export var folder := "user://replays"
## How many recordings to keep in each role's folder. Older ones are deleted when a new one starts. 0 keeps them all.
@export_range(0, 1000, 1, "or_greater") var keep_recordings := 10
## How long each block is, in seconds. Seeking starts from a block's keyframe, so shorter blocks seek faster but make bigger files.
@export_range(0.1, 10.0, 0.1) var block_seconds := 1.0
## Off: blocks are written on the main thread, at once (ReplayWriter.use_thread). For tests.
@export var write_on_thread := true
## Claude 2026-11-16, safeguards (see the top of the file). 0 switches each one off.
## The longest a recording may be, in seconds: 3 hours by default (the owner's call).
@export_range(0.0, 86400.0, 60.0, "or_greater") var max_recording_seconds := 10800.0
## The biggest a recording's file may get, in megabytes.
@export_range(0, 100000, 1, "or_greater") var max_file_megabytes := 2048
## The least free disk space recording needs, in megabytes.
@export_range(0, 100000, 1, "or_greater") var min_free_megabytes := 1024
## The most a role's folder may hold, in megabytes. Older recordings are deleted to stay under it.
@export_range(0, 1000000, 1, "or_greater") var max_folder_megabytes := 4096
## How many finished blocks may wait for the writer before the recording gives up: with 1 s blocks, how many seconds the disk may
## fall behind. Claude 2026-11-16: 60 (about a minute), the owner's call, was 30; at mass-battle sizes a full queue is a few MB.
@export_range(1, 3600, 1, "or_greater") var max_queued_blocks := 60

var _channels: Array[ReplayChannel] = []
var _recording := false
var _path := ""
var _writer: ReplayWriter = null
var _driver: Node = null
var _ids := {} # pawn instance id -> replay id
var _pawns := {} # replay id -> pawn, while it's in the tree
var _arrived: Array = [] # pawns that entered the tree since last tick, handed to the channels at the next tick
var _next_local_id := LOCAL_IDS_START
var _block: Array[StreamPeerBuffer] = [] # one buffer per channel, in the order of _channels
var _block_first_tick := -1
var _block_ticks := 0
var _ticks_recorded := 0
var _stopped_reason := "" # Claude 2026-11-16: why the last recording stopped, if a safeguard stopped it
var _next_space_check_msec := 0


func _init() -> void:
	# GDScript note: this module does nothing per frame; it works from TickDriver's after_tick signal.
	set_process(false)
	set_physics_process(false)
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


## Adds a game's own channel, before recording starts. Its id must be unused; the base's are 1 to 5, so a game uses 100 and up.
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


## Starts recording to a new file. role is "host" (also for offline play) or "client"; it picks the folder. Stops any recording
## already running first. Returns the error if the file couldn't be made.
func start_recording(role: String) -> Error:
	stop_recording()
	if not enabled or _driver == null:
		return ERR_UNAVAILABLE
	var role_folder := folder.path_join(role)
	var made := DirAccess.make_dir_recursive_absolute(role_folder)
	if made != OK:
		push_warning("ReplayRecorder: couldn't make %s (error %d), so nothing is recorded." % [role_folder, made])
		return made
	# Claude 2026-11-16: refuses to start without room on the disk.
	var space := _free_megabytes(role_folder)
	if min_free_megabytes > 0 and space >= 0 and space < min_free_megabytes:
		push_warning("ReplayRecorder: only %d MB free, under min_free_megabytes (%d), so nothing is recorded." % [space, min_free_megabytes])
		_stopped_reason = "not enough disk space"
		return ERR_FILE_NO_PERMISSION
	_prune(role_folder, keep_recordings - 1) # room for the new one
	# GDScript note: the date and time with a space, so it's changed to a file-name-friendly form.
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	_path = role_folder.path_join("%s.%s" % [stamp, FILE_EXTENSION])
	var suffix := 2
	while FileAccess.file_exists(_path): # two recordings started in the same second
		_path = role_folder.path_join("%s_%d.%s" % [stamp, suffix, FILE_EXTENSION])
		suffix += 1
	_writer = ReplayWriter.new()
	_writer.use_thread = write_on_thread
	_writer.max_queued_blocks = max_queued_blocks # Claude 2026-11-16
	var error := _writer.open(_path, _header(role))
	if error != OK:
		push_warning("ReplayRecorder: couldn't create %s (error %d), so nothing is recorded." % [_path, error])
		_writer = null
		return error
	_recording = true
	_stopped_reason = ""
	_next_space_check_msec = Time.get_ticks_msec() + 60000
	_ids.clear()
	_pawns.clear()
	_arrived.clear()
	_next_local_id = LOCAL_IDS_START
	_ticks_recorded = 0
	_start_block()
	for channel in _channels:
		channel.begin(self)
	# Pawns already here are handed over at the first tick, like any that arrive later.
	for node in get_tree().get_nodes_in_group(TerrainBodyLifter.GROUP): # every Pawn joins this group when it enters the tree
		if node is Pawn:
			_arrived.append(node)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	_driver.after_tick.connect(_on_after_tick)
	recording_started.emit(_path)
	return OK


## Stops recording: the block so far is written, the file closed and the writer's thread stopped. Does nothing if not recording.
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
	_pawns.clear()
	_arrived.clear()
	recording_stopped.emit(_path)


func is_recording() -> bool:
	return _recording


## Claude 2026-11-16: why the last recording stopped on its own (a safeguard), or "" if it was stopped by stop_recording() or is
## still running.
func get_stopped_reason() -> String:
	return _stopped_reason


## The file being recorded, or the last one recorded. GDScript note: not get_path(), which every Node already has (its place in the
## scene tree).
func get_recording_path() -> String:
	return _path


## How many ticks this recording holds so far.
func get_ticks_recorded() -> int:
	return _ticks_recorded


## The file's size so far, in bytes (as of the last block written).
func get_bytes_written() -> int:
	return _writer.get_bytes_written() if _writer else 0


## A pawn's id in the recording: its NetworkEntity id where it has one (the same on every machine), or one handed out here. 0 for
## null, or for anything that isn't a pawn being recorded.
func get_replay_id(node: Node) -> int:
	if not is_instance_valid(node):
		return 0
	return _ids.get(node.get_instance_id(), 0)


# --- Each tick ---


func _on_after_tick(_dt: float, tick: int) -> void:
	var started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
	_record_tick(tick)
	PerfScopes.end(&"replay.record", started)


# Claude 2026-11-16: the work itself, timed by _on_after_tick.
func _record_tick(tick: int) -> void:
	_hand_over_arrivals()
	if _block_first_tick < 0:
		_block_first_tick = tick
	var keyframe := _block_ticks == 0
	for i in _channels.size():
		var out := _block[i]
		# A tick's part: its number, its byte count (filled in once known), then the channel's bytes.
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
	# GDScript note: the loop variable isn't typed, because a freed pawn can't be put in a Pawn-typed variable; it's checked first.
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
		_pawns[id] = pawn
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
	_pawns.erase(id)
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


# A block (replay spec section 2): first tick (u32), tick count (u16), channel count (u16), then each channel's id (u16), byte count
# (u32) and bytes. Handed to the writer, which compresses it on its thread.
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
	# Claude 2026-11-16: the writer refuses a block when too many are already waiting, or after a write failed.
	if not _writer.push_block(out.data_array):
		_safeguard_stop.call_deferred("the writer fell %d blocks behind or failed to write (error %d)" % [max_queued_blocks, _writer.get_error()])
	_block_ticks = 0
	_check_limits()


# Claude 2026-11-16: the safeguards checked once a block (see the top of the file). Stopping is deferred to the end of the frame,
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


# The header (replay spec section 2): magic, format version (u16), the fields' byte count (u32), then the fields as one Dictionary.
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


# Deletes the oldest recordings in a folder until at most keep are left. File names start with the date and time, so sorting them
# by name sorts them by age.
func _prune(role_folder: String, keep: int) -> void:
	if keep_recordings <= 0:
		return
	var names: Array[String] = []
	for file_name in DirAccess.get_files_at(role_folder):
		if file_name.get_extension() == FILE_EXTENSION:
			names.append(file_name)
	names.sort()
	# Claude 2026-11-16: also down to max_folder_megabytes, oldest first, and never the file being recorded; a file another instance
	# still has open can't be deleted, and is left.
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
