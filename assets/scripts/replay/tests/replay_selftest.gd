## Written by Claude (claude-opus-5-5), 2026-11-15: headless self-test for replay v0 (docs/replay/REPLAY_SPEC.md): ReplayRecorder
## records a small scene through its writer thread, and ReplayReader reads back exactly what happened: motion, input, spawns and
## despawns, chunks and sources, gameplay events (a fall and a death), keyframes, a file cut short, a channel the reader doesn't
## know, and old recordings being pruned.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/replay/tests/replay_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]
const FOLDER := "user://replay_selftest"
const RUN_TICKS := 180


# A game's own channel, for the "unknown channel" checks: each tick, the tick number and three bytes the built-in channels never read.
class TestChannel extends ReplayChannel:
	func _init() -> void:
		channel_id = 120
		channel_name = "test"

	func write_tick(tick: int, out: StreamPeerBuffer, _keyframe: bool) -> void:
		out.put_u32(tick)
		out.put_data(PackedByteArray([1, 2, 3]))

	func read_tick(_tick: int, data: StreamPeerBuffer, _keyframe: bool, state: Dictionary) -> void:
		state["last"] = data.get_u32()


var _expected := {} # tick -> replay id -> [position, velocity, flags, move_input, held_actions]
var _recorder: ReplayRecorder = null


func _ready() -> void:
	print("--- Replay self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	_recorder = GameMode.replay_recorder
	_check(_recorder != null, "GameMode has a replay recorder by default")
	if _recorder == null:
		_finish()
		return
	_clear_folder()
	_recorder.folder = FOLDER
	_recorder.headless_runs_apart = false # Claude 2026-11-16: this test checks the folder rules themselves, and always runs headless
	_recorder.keep_recordings = 3
	_recorder.block_seconds = 0.5 # 30 ticks a block, so the run spans several
	_recorder.add_channel(TestChannel.new())
	# Old recordings, older than any real one by name, so the recorder prunes them.
	DirAccess.make_dir_recursive_absolute(FOLDER.path_join("host"))
	for i in 5:
		FileAccess.open(FOLDER.path_join("host/2000-01-01_00-00-0%d.pbreplay" % i), FileAccess.WRITE).store_8(0)
	await _scene_and_run()
	_finish()


func _scene_and_run() -> void:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10, 1, 10)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	var kill_floor := KillFloor.new()
	kill_floor.position.y = -20.0
	add_child(kill_floor)
	var terrain := TerrainGenerator.new()
	terrain.build_on_start = false
	terrain.chunk_size = 32.0
	terrain.chunk_resolution = 4
	terrain.build_collision = false
	terrain.position = Vector3(1000, 0, 0) # well away, so nothing stands on it
	add_child(terrain)
	var source := StreamingSource.new()
	source.position = Vector3(1000, 0, 0)
	add_child(source)
	# The terrain means the AI switch-off is watching: pawns without a chunk source of their own freeze where it has no ground, which
	# here is everywhere but its one chunk. So the standing and falling pawns keep the world loaded themselves, and stay running; the
	# leaving one doesn't, and freezes, which is recorded too.
	var standing := _pawn(Vector3(0, 0.1, 0), "Standing")
	standing.keeps_world_loaded = true
	var falling := _pawn(Vector3(40, 0.1, 0), "Falling")
	falling.keeps_world_loaded = true
	var leaving := _pawn(Vector3(2, 0.1, 2), "Leaving")
	await _ticks(2)

	var error := _recorder.start_recording("host")
	_check(error == OK and _recorder.is_recording(), "it starts recording (error %d)" % error)
	var path := _recorder.get_recording_path()
	_check(path.begins_with(FOLDER.path_join("host")) and path.ends_with(".pbreplay"), "into the host folder (%s)" % path)
	var kept := DirAccess.get_files_at(FOLDER.path_join("host")).size()
	_check(kept == 3, "older recordings are pruned to keep_recordings (%d files)" % kept)
	TickDriver.after_tick.connect(_capture) # after the recorder's, so it sees what was recorded
	var arriving: Pawn = null
	var leaving_id := 0
	var leaving_gone_tick := -1
	var arriving_tick := -1
	var bytes_after_one_second := 0
	for i in RUN_TICKS:
		await get_tree().physics_frame
		match i:
			20:
				terrain.load_chunk(Vector2i(0, 0))
			30:
				leaving_id = _recorder.get_replay_id(leaving)
				leaving.queue_free()
				leaving_gone_tick = TickDriver.tick
			45:
				arriving = _pawn(Vector3(-2, 0.1, -2), "Arriving")
				arriving_tick = TickDriver.tick
			50:
				source.active = false
			60:
				source.active = true
				terrain.unload_chunk(Vector2i(0, 0))
			70:
				# A held action and a move direction on the standing pawn, written straight onto it, which the input channel records.
				standing.controller_manager.held_actions = 5
			90:
				bytes_after_one_second = _recorder.get_bytes_written()
	var standing_id := _recorder.get_replay_id(standing)
	var falling_id := _recorder.get_replay_id(falling)
	var arriving_id := _recorder.get_replay_id(arriving)
	TickDriver.after_tick.disconnect(_capture)
	_check(bytes_after_one_second > 200, "blocks are written while recording, on the writer's thread (%d bytes after 1.5 s)" % bytes_after_one_second)
	# Claude 2026-11-16 (wider audit): a tick that isn't after the last one recorded (a client's clock jumping back) is left out.
	var before_repeat := _recorder.get_ticks_recorded()
	_recorder._record_tick(TickDriver.tick - 3)
	_check(_recorder.get_ticks_recorded() == before_repeat, "a tick that isn't after the last one recorded is left out, so the file's ticks only go up")
	var ticks := _recorder.get_ticks_recorded()
	_recorder.stop_recording()
	_check(not _recorder.is_recording(), "it stops")
	_check(standing_id >= ReplayRecorder.LOCAL_IDS_START and falling_id != standing_id, "pawns that aren't networked get ids of their own")

	var reader := ReplayReader.new()
	_check(reader.open(path) == OK, "the reader opens it")
	var header := reader.get_header()
	# Claude 2026-11-16: the base's five, the test's own (120), and diagnostics (6) in debug builds, where its module adds it.
	var channel_ids: Array = header.get("channels", []).map(func(info: Dictionary) -> int: return info.id)
	_check(header.get("tick_rate") == 60 and header.get("role") == "host" and [1, 2, 3, 4, 5, 120].all(func(id: int) -> bool: return channel_ids.has(id)),
		"the header has the tick rate, role and channels (%s)" % str(channel_ids))
	_check(reader.get_last_tick() - reader.get_first_tick() + 1 == ticks and not reader.is_cut_short(),
		"every tick is there (%d of %d), and nothing is cut short" % [reader.get_last_tick() - reader.get_first_tick() + 1, ticks])
	_check(reader.get_block_count() == ceili(ticks / 30.0), "in blocks of 30 ticks (%d blocks)" % reader.get_block_count())
	_test_motion_and_input(reader, standing_id, falling_id)
	_test_spawns(reader, leaving_id, leaving_gone_tick, arriving_id, arriving_tick)
	_test_events(reader, falling_id)
	_test_damaged(path, reader)
	_test_unknown_channel(path)
	await _test_viewer(path, reader)
	await _test_safeguards()
	var size := FileAccess.get_file_as_bytes(path).size()
	print("  (size: %d bytes for %d ticks of 3 to 4 pawns, %.1f bytes a pawn a tick)" % [size, ticks, float(size) / (ticks * 3.5)])
	standing.free()
	falling.free()
	if is_instance_valid(arriving):
		arriving.free()


func _test_motion_and_input(reader: ReplayReader, standing_id: int, falling_id: int) -> void:
	var motion_ok := true
	var input_ok := true
	var compared := 0
	var detail := ""
	for tick: int in _expected:
		var frame := reader.get_frame(tick)
		for id: int in _expected[tick]:
			if not frame.pawns.has(id):
				continue # handed to the recorder a tick after it arrived
			var want: Array = _expected[tick][id]
			var got: Dictionary = frame.pawns[id]
			var motion: Variant = got.motion
			var input: Variant = got.input
			# Claude 2026-11-15: positions to the millimetre (motion channel version 2), so within half of one.
			if motion == null or not _within(motion.position, want[0], 0.0006) or not motion.velocity.is_equal_approx(want[1]) and \
					motion.velocity.distance_to(want[1]) > 0.01 * maxf(1.0, want[1].length()) or motion.flags != want[2]:
				if motion_ok:
					detail = "tick %d pawn %d: %s vs %s" % [tick, id, str(motion), str(want)]
				motion_ok = false
			if input == null or input.held_actions != want[4] or not input.move_input.is_equal_approx(want[3]):
				input_ok = false
			compared += 1
	_check(motion_ok and compared > RUN_TICKS * 2, "position (to the millimetre), velocity (to half precision) and flags match every tick (%d compared) %s" % [compared, detail])
	_check(input_ok, "and so do the inputs")
	# The standing pawn settles and sleeps, so between keyframes it writes nothing; a frame partway into a block still has its record.
	var last := reader.get_last_tick()
	var standing: Variant = reader.get_frame(last - 1).pawns.get(standing_id, {}).get("motion")
	_check(standing != null and (standing.flags & ReplayMotionChannel.FLAG_GROUNDED) != 0, "a pawn that hasn't changed still has its record between keyframes")
	var falling_frame: Variant = reader.get_frame(last).pawns.get(falling_id, {}).get("motion")
	_check(falling_frame != null and (falling_frame.flags & ReplayMotionChannel.FLAG_DEAD) != 0 and falling_frame.position.y < -20.0,
		"the falling pawn is dead below the kill floor at the end")


func _test_spawns(reader: ReplayReader, leaving_id: int, gone_tick: int, arriving_id: int, arrived_tick: int) -> void:
	_check(reader.get_frame(gone_tick - 2).pawns.has(leaving_id) and not reader.get_frame(gone_tick + 2).pawns.has(leaving_id),
		"a pawn that's freed is there before and gone after")
	_check(not reader.get_frame(arrived_tick - 2).pawns.has(arriving_id) and reader.get_frame(arrived_tick + 2).pawns.has(arriving_id),
		"a pawn that arrives isn't there before, and is after")
	var info: Dictionary = reader.get_frame(arrived_tick + 2).pawns.get(arriving_id, {})
	_check(info.get("name") == "Arriving" and info.get("scene") == PAWN_SCENE, "with its name and scene")


func _test_events(reader: ReplayReader, falling_id: int) -> void:
	var events := reader.get_events(reader.get_first_tick(), reader.get_last_tick())
	var kinds := {}
	for event: Dictionary in events:
		kinds[event.kind] = kinds.get(event.kind, 0) + 1
	# Claude 2026-11-16 (pawn M2): a switched-off source is "source_removed" now, and switched back on, "source_added" again.
	for kind in ["spawned", "despawned", "chunk_built", "chunk_removed", "source_added", "source_removed", "fell", "died", "frozen"]:
		_check(kinds.has(kind), "the %s event is recorded" % kind)
	var fell: Array = events.filter(func(event: Dictionary) -> bool: return event.kind == "fell")
	_check(fell.size() == 1 and fell[0].id == falling_id and str(fell[0].data.get("report", "")).contains("Falling"),
		"the fall names the pawn, with the kill floor's report")
	# Events are in the frame of their own tick only.
	if not fell.is_empty():
		var frame := reader.get_frame(fell[0].tick)
		_check(frame.events.any(func(event: Dictionary) -> bool: return event.kind == "fell"), "and in that tick's frame")
	# The chunk: built at one tick, removed later, and in the world state in between.
	var built: Array = events.filter(func(event: Dictionary) -> bool: return event.kind == "chunk_built")
	var removed: Array = events.filter(func(event: Dictionary) -> bool: return event.kind == "chunk_removed")
	if not built.is_empty() and not removed.is_empty():
		var between := reader.get_frame(floori((built[0].tick + removed[0].tick) / 2.0))
		var terrain: Dictionary = between.terrains.values()[0] if not between.terrains.is_empty() else {}
		_check(terrain.get("chunks", {}).has(Vector2i(0, 0)) and terrain.get("chunk_size") == 32.0, "the world state has the chunk while it's built")
		var after := reader.get_frame(removed[0].tick + 1)
		_check(not after.terrains.values()[0].chunks.has(Vector2i(0, 0)), "and not after it's removed")
	var removed_sources := events.filter(func(event: Dictionary) -> bool: return event.kind == "source_removed")
	var count_before: int = reader.get_frame(removed_sources[0].tick - 1).sources.size() if not removed_sources.is_empty() else -1
	var count_after: int = reader.get_frame(removed_sources[0].tick).sources.size() if not removed_sources.is_empty() else -1
	_check(count_after == count_before - 1, "a switched-off source leaves the world state (%d sources, then %d)" % [count_before, count_after])


func _test_damaged(path: String, whole: ReplayReader) -> void:
	var bytes := FileAccess.get_file_as_bytes(path)
	var cut_path := FOLDER.path_join("cut.bin")
	var file := FileAccess.open(cut_path, FileAccess.WRITE)
	file.store_buffer(bytes.slice(0, bytes.size() - 5))
	file.close()
	var reader := ReplayReader.new()
	_check(reader.open(cut_path) == OK and reader.is_cut_short() and reader.get_block_count() == whole.get_block_count() - 1,
		"a file cut short opens with every whole block (%d of %d)" % [reader.get_block_count(), whole.get_block_count()])
	var junk := FileAccess.open(FOLDER.path_join("junk.bin"), FileAccess.WRITE)
	junk.store_string("not a replay")
	junk.close()
	_check(ReplayReader.new().open(FOLDER.path_join("junk.bin")) == ERR_FILE_UNRECOGNIZED, "a file that isn't a replay is refused")


func _test_unknown_channel(path: String) -> void:
	# The recording has the test channel (id 120). A reader without its class skips it; one with it reads it.
	var without := ReplayReader.new()
	without.open(path)
	var middle := floori((without.get_first_tick() + without.get_last_tick()) / 2.0)
	_check(not without.get_frame(middle).pawns.is_empty(), "a reader without a channel's class skips it and reads the rest")
	var with := ReplayReader.new()
	with.add_channel(TestChannel.new())
	with.open(path)
	with.get_frame(middle)
	var state: Dictionary = with._decoded(with._block_index(middle)).states[0].get(120, {})
	_check(state.get("last", -1) >= with.get_first_tick(), "one with it reads it")


# Claude 2026-11-16: the safeguards (ReplayRecorder's top comment): a length cap stops a recording, a disk without room refuses one,
# a folder over its size is pruned oldest first, and the writer refuses blocks once its queue is full.
func _test_safeguards() -> void:
	var host_folder := FOLDER.path_join("host")
	# A length cap: 1 s, so the recording stops on its own after about 60 ticks, with a reason.
	_recorder.max_recording_seconds = 1.0
	_recorder.start_recording("host")
	var capped := _recorder.get_recording_path()
	for i in 150:
		await get_tree().physics_frame
		if not _recorder.is_recording():
			break
	_check(not _recorder.is_recording() and _recorder.get_stopped_reason().contains("max_recording_seconds"),
		"a recording stops by itself at max_recording_seconds (%s)" % _recorder.get_stopped_reason())
	var capped_reader := ReplayReader.new()
	_check(capped_reader.open(capped) == OK and capped_reader.get_last_tick() - capped_reader.get_first_tick() < 75,
		"and its file is complete up to there (%d ticks)" % (capped_reader.get_last_tick() - capped_reader.get_first_tick() + 1))
	_recorder.max_recording_seconds = 10800.0
	# No room on the disk: an impossible minimum, so it refuses to start.
	_recorder.min_free_megabytes = 1 << 40
	var refused := _recorder.start_recording("host")
	_check(refused != OK and not _recorder.is_recording() and _recorder.get_stopped_reason() == "not enough disk space",
		"it won't start without min_free_megabytes free on the disk")
	_recorder.min_free_megabytes = 1024
	# A folder over max_folder_megabytes: three old 1 MB files and a 2 MB limit, so the oldest go when the next recording starts.
	for file_name in DirAccess.get_files_at(host_folder):
		DirAccess.remove_absolute(host_folder.path_join(file_name))
	var megabyte := PackedByteArray()
	megabyte.resize(1048576)
	for i in 3:
		var big := FileAccess.open(host_folder.path_join("2000-01-01_00-00-1%d.pbreplay" % i), FileAccess.WRITE)
		big.store_buffer(megabyte)
		big.close()
	_recorder.max_folder_megabytes = 2
	_recorder.start_recording("host")
	_recorder.stop_recording()
	var left := DirAccess.get_files_at(host_folder)
	_check(left.size() == 2 and not Array(left).has("2000-01-01_00-00-10.pbreplay") and not Array(left).has("2000-01-01_00-00-11.pbreplay"),
		"a folder over max_folder_megabytes loses its oldest recordings first (%s)" % ", ".join(left))
	_recorder.max_folder_megabytes = 4096
	# The writer's queue: the test holds the writer's lock, so its thread can't take blocks, and the queue fills.
	var writer := ReplayWriter.new()
	writer.max_queued_blocks = 3
	writer.open(FOLDER.path_join("queue.bin"), PackedByteArray([1, 2, 3, 4]))
	writer._mutex.lock() # GDScript note: Godot's Mutex can be locked again by the same thread, so push_block still gets in
	var accepted := 0
	for i in 6:
		if writer.push_block(PackedByteArray([i, i, i, i, i, i, i, i])):
			accepted += 1
	writer._mutex.unlock()
	writer.close()
	_check(accepted == 3, "the writer refuses blocks once max_queued_blocks are waiting (%d of 6 taken)" % accepted)


# The viewer opens the file and shows a ghost for each pawn that has a record, at any tick.
func _test_viewer(path: String, reader: ReplayReader) -> void:
	var viewer: ReplayViewer = load("res://assets/scenes/replay/replay_viewer.tscn").instantiate()
	viewer.file_path = path
	add_child(viewer)
	await get_tree().process_frame
	_check(viewer.get_reader() != null, "the viewer opens the recording")
	var middle := floori((reader.get_first_tick() + reader.get_last_tick()) / 2.0)
	viewer.show_tick(middle)
	var want := 0
	for id: int in reader.get_frame(middle).pawns:
		if reader.get_frame(middle).pawns[id].motion != null:
			want += 1
	_check(viewer.get_shown_tick() == reader.get_frame(middle).tick and viewer.get_visible_ghost_count() == want,
		"and shows a ghost for each pawn at a tick (%d of %d)" % [viewer.get_visible_ghost_count(), want])
	viewer.show_tick(reader.get_last_tick())
	_check(viewer.get_shown_tick() == reader.get_last_tick(), "and can jump to the end")
	viewer.free()


func _capture(_dt: float, tick: int) -> void:
	var now := {}
	for node in get_tree().get_nodes_in_group(TerrainBodyLifter.GROUP):
		var pawn := node as Pawn
		if pawn == null or pawn.is_queued_for_deletion():
			continue
		var id := _recorder.get_replay_id(pawn)
		if id != 0:
			now[id] = [pawn.global_position, pawn.velocity, ReplayMotionChannel.flags_of(pawn), pawn.controller_manager.move_input, pawn.controller_manager.held_actions]
	_expected[tick] = now


static func _within(a: Vector3, b: Vector3, tolerance: float) -> bool:
	return absf(a.x - b.x) <= tolerance and absf(a.y - b.y) <= tolerance and absf(a.z - b.z) <= tolerance


func _pawn(at: Vector3, pawn_name: String) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.name = pawn_name
	pawn.skip_default_parts = NO_AI
	pawn.position = at
	add_child(pawn)
	return pawn


func _clear_folder() -> void:
	for sub in ["", "host", "client"]:
		var dir := FOLDER.path_join(sub)
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for file_name in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute(dir.path_join(file_name))


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _finish() -> void:
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)
