## Written by Claude (claude-opus-5-5), 2026-11-04: one machine in a multiplayer test, run as its own Godot process.
## net_selftest.gd and net_measure.gd start several of these with command-line settings. Each one builds a small arena, plays
## its part for a set time, writes what happened to a JSON file, and quits. NetworkTime is a single autoload, so a server and
## a client can't share one process.
##
## Settings, after "--" on the command line:
##   --role=server|client  --name=a  --port=24500  --out=<file>  --seconds=8
##   --latency=50 --jitter=10 --loss=0.05     one-way fake network conditions for this machine's sending
##   --mode=seek|strafe|shoot|lead|idle       what this machine's pawn does (see NetTestPawn.gd)
##   --delay=2           client: wait this long before joining
##   --leave-after=4     client: leave after this long
##   --salt=1            changes the content hash, so the server refuses this client
##   --garbage           client: also sends broken packets, and input for a pawn it doesn't own
##   --shove-at=240      server: moves the first pawn 2 m on this tick, which no client can predict
##   --custom            everyone: uses the pawn with custom state (NetTestCustomPawn)
##   --bonus-at=240      server: sets the first pawn's bonus on this tick, which no client can predict
##   --no-rewind         server: turns lag compensation off, to compare
##   --off=a,b  --on=a,b      turn NetworkSession features off or on at the start
##   --switch=5:lag_compensation_enabled:0    turn a feature on or off after this many seconds
##   --allow-debug       server: obey test switches sent by clients
##   --preset=worst      this machine sends and receives through a NetFakeConditions preset
##   --bench-ping=120    sets the round trip through NetTestBench, the same way its keys do
##   --terrain           hills with collision and nav, instead of the flat arena. The same on every machine
##   --walkers=4         server: gives each client this many pawns
##   --ai-mode=walk      server: what the --ai pawns do
##   --hitch=5:200       every 5 seconds, this machine freezes for 200 ms
##   --profile           time each tick phase, and the whole physics frame
##   --no-log            don't record every pawn's position, which takes time and memory at large counts
##   --measure-after=6   start measuring after this many seconds, instead of 2
##   --repath-every=30   every walker finds a new path this often, in ticks
##   --edit-every=180    every machine raises or digs the terrain this often, in ticks, at the same place on the same tick number
##   --edit-until=800    stops editing after this tick, to see whether anything recovers
##   --timeline=0:10,4:100    latency over time, both ways on this machine, as seconds:milliseconds
##   --conditions-seed=7      a fixed seed for the fake network
##   --claim=21          shooter: claims to be seeing others this many ticks behind, whatever's true
##   --lead-seconds=0.3  shooter: how far ahead of the drawn target to aim
##   --predicted         everyone: other pawns are predicted (is_predicted)
##   --ai=2              server: adds this many AI pawns nobody owns
##   --follow            client: remote pawns stand on server data during a rollback, to compare
extends Node

const PAWN_SCENE := "res://assets/scripts/netcode/tests/net_test_pawn.tscn"
const CUSTOM_PAWN_SCENE := "res://assets/scripts/netcode/tests/net_test_pawn_custom.tscn"
const EDITS_FROM_TICK := 300

var settings: Dictionary = {}
var session: NetworkSessionSingleton
var driver: NetworkTimeSingleton
var started_usec := 0
var log_positions: Dictionary = {}      # entity id -> {tick: [x, y, z]}
var log_views: Dictionary = {}          # entity id -> {tick: [render tick, x, y, z]}
var measure_from_tick := -1
var result: Dictionary = {"joined": false, "refused": "", "spawned": [], "despawned": [], "disconnected": false}
var _left := false
var _finished := false
var _next_slot := 0
var _shoved := false
var _garbage_sent := false
var _ai_spawned := false
var _switched := false
var _nav_tick_total_usec := 0
var _nav_tick_count := 0
var _nav_tick_worst_usec := 0
var _edit_total_usec := 0
var _edit_worst_usec := 0
var _edits := 0
var _physics_total_ms := 0.0
var _physics_samples := 0
var _physics_worst_ms := 0.0
var _physics_over_budget := 0
var _physics_by_second: Dictionary = {}
var _terrain: Node3D = null
var _next_hitch_seconds := -1.0
var _loop_started_usec := 0
var _logging_usec := 0
var _loop_total_usec := 0
var _loop_count := 0
var _loop_worst_usec := 0
var _loops_over_budget := 0
var _hitches := 0
var _summaries: Dictionary = {}          # entity id -> latest summary, kept after the entity is gone


func _ready() -> void:
	session = get_node("/root/NetworkSession")
	driver = get_node("/root/NetworkTime")
	_read_settings()
	if settings.has("terrain"):
		_build_terrain()
	else:
		_build_arena()
	session.world_root = self
	session.bind_address = "127.0.0.1"
	session.register_type("pawn", load(CUSTOM_PAWN_SCENE if settings.has("custom") else PAWN_SCENE))
	session.content_hash_salt = int(settings.get("salt", 0))
	session.lag_compensation_enabled = not settings.has("no-rewind")
	session.default_predicted = settings.has("predicted")
	session.fake.latency_ms = float(settings.get("latency", 0))
	session.fake.jitter_ms = float(settings.get("jitter", 0))
	session.fake.loss = float(settings.get("loss", 0))
	var conditions_seed := int(settings.get("conditions-seed", hash(settings.get("name", "server"))))
	session.fake.set_seed(conditions_seed)
	session.fake_in.set_seed(conditions_seed + 1)
	if settings.has("preset"):
		session.fake.apply_preset(settings["preset"])
		session.fake_in.apply_preset(settings["preset"])
	if settings.has("timeline"):
		var points: Array = []
		for part in String(settings["timeline"]).split(","):
			var pieces := part.split(":")
			points.append([float(pieces[0]), float(pieces[1])])
		session.fake.timeline = points
		session.fake_in.timeline = points
	if settings.has("bench-ping"):
		var bench := NetTestBench.new()
		add_child(bench)
		bench.set_ping(float(settings["bench-ping"]))
	session.allow_debug_commands = settings.has("allow-debug")
	for feature in String(settings.get("off", "")).split(",", false):
		session.set(feature, false)
	for feature in String(settings.get("on", "")).split(",", false):
		session.set(feature, true)
	NetTestPawn.forced_claim = float(settings.get("claim", -1))
	NetTestPawn.default_mode = settings.get("mode", "seek")
	NetTestPawn.lead_seconds = float(settings.get("lead-seconds", 0))
	NetTestPawn.ai_mode = settings.get("ai-mode", "idle")
	NetTestPawn.repath_every = int(settings.get("repath-every", 0))
	session.joined.connect(func() -> void:
		result["joined"] = true
		result["peer_when_joined"] = session.get_local_peer())
	session.refused.connect(func(reason: String) -> void: result["refused"] = reason)
	session.disconnected.connect(func() -> void: result["disconnected"] = true)
	session.entity_spawned.connect(_on_entity_spawned)
	session.entity_despawned.connect(func(entity_id: int) -> void: result["despawned"].append(entity_id))
	session.player_connected.connect(_on_player_connected)
	driver.before_tick_loop.connect(func() -> void: _loop_started_usec = Time.get_ticks_usec())
	driver.after_tick_loop.connect(_on_loop_finished)
	driver.after_tick.connect(_on_after_tick)
	driver.before_tick.connect(_on_before_tick)
	started_usec = Time.get_ticks_usec()
	if settings.get("role", "server") == "server":
		var error := session.host(int(settings.get("port", 24500)))
		if error != OK:
			result["refused"] = "host failed: %d" % error
			_finish()
	elif not settings.has("delay"):
		_join()


func _physics_process(delta: float) -> void:
	if settings.has("terrain"):
		var started := Time.get_ticks_usec()
		Engine.get_singleton(&"NavServer").tick(delta)
		var spent := Time.get_ticks_usec() - started
		if measure_from_tick >= 0:
			_nav_tick_total_usec += spent
			_nav_tick_count += 1
			_nav_tick_worst_usec = maxi(_nav_tick_worst_usec, spent)


func _process(_delta: float) -> void:
	var elapsed := (Time.get_ticks_usec() - started_usec) / 1000000.0
	if settings.has("hitch") and elapsed >= 3.0:
		var parts := String(settings["hitch"]).split(":")
		if _next_hitch_seconds < 0.0:
			_next_hitch_seconds = elapsed + float(parts[0])
		elif elapsed >= _next_hitch_seconds:
			_next_hitch_seconds = elapsed + float(parts[0])
			_hitches += 1
			OS.delay_msec(int(parts[1]))
	if settings.has("delay") and not result.has("join_started") and elapsed >= float(settings["delay"]):
		_join()
	if settings.has("leave-after") and not _left and elapsed >= float(settings["leave-after"]):
		_left = true
		_capture_summary()
		session.leave()
	if settings.has("garbage") and not _garbage_sent and result["joined"] and elapsed >= 2.0:
		_garbage_sent = true
		_send_garbage()
	if settings.has("switch") and not _switched and elapsed >= float(String(settings["switch"]).split(":")[0]):
		_switched = true
		var parts := String(settings["switch"]).split(":")
		session.set_feature(parts[1], parts[2] == "1")
	if settings.has("profile") and measure_from_tick >= 0:
		var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		_physics_total_ms += physics_ms
		_physics_samples += 1
		_physics_worst_ms = maxf(_physics_worst_ms, physics_ms)
		var second := int(elapsed)
		if not _physics_by_second.has(second):
			_physics_by_second[second] = [0.0, 0]
		_physics_by_second[second][0] += physics_ms
		_physics_by_second[second][1] += 1
		if physics_ms > 16.667:
			_physics_over_budget += 1
	if measure_from_tick < 0 and elapsed >= float(settings.get("measure-after", 2.0)) and driver.active:
		_start_measuring()
	if not _finished and elapsed >= float(settings.get("seconds", 8)):
		_finish()


func _join() -> void:
	result["join_started"] = true
	session.join("127.0.0.1", int(settings.get("port", 24500)))


func _on_entity_spawned(entity: NetworkEntity) -> void:
	result["spawned"].append(_describe(entity))
	if settings.has("follow") and entity.state:
		entity.state.follows_during_rollback = true


func _on_player_connected(peer: int) -> void:
	for i in int(settings.get("walkers", 1)):
		session.spawn("pawn", peer, _next_spawn_point())
	if not _ai_spawned:
		_ai_spawned = true
		for i in int(settings.get("ai", 0)):
			session.spawn("pawn", 0, _next_spawn_point())


## Spread out in a growing ring around the middle, starting with the four original spots.
func _next_spawn_point() -> Vector3:
	var slots := [Vector3(-3, 0.1, 0), Vector3(3, 0.1, 0), Vector3(0, 0.1, -3), Vector3(0, 0.1, 3)]
	var index := _next_slot
	_next_slot += 1
	if index < slots.size():
		return slots[index]
	var angle := index * 2.4
	var radius := 3.0 + 0.7 * sqrt(float(index)) * 2.0
	var at := Vector3(cos(angle) * radius, 0.3, sin(angle) * radius)
	# Standing on whatever's there, including the top of the test wall. Inside a wall, a pawn falls straight through the terrain.
	if _terrain:
		at.y = float(_terrain.call("height_at", at.x, at.z)) + 0.3
	return at


func _on_loop_finished() -> void:
	# This test's own logging isn't part of what's being measured.
	var spent := Time.get_ticks_usec() - _loop_started_usec - _logging_usec
	_logging_usec = 0
	_loop_total_usec += spent
	_loop_count += 1
	_loop_worst_usec = maxi(_loop_worst_usec, spent)
	if spent > 16667:
		_loops_over_budget += 1


func _on_before_tick(_dt: float, tick: int) -> void:
	var edit_every := int(settings.get("edit-every", 0))
	# From a fixed tick, so every machine makes the same edits and has the same ground.
	if edit_every > 0 and _terrain and tick % edit_every == 0 and tick >= EDITS_FROM_TICK and tick <= int(settings.get("edit-until", 1000000)):
		var pick := RandomNumberGenerator.new()
		pick.seed = tick
		var started := Time.get_ticks_usec()
		_terrain.call("edit", Vector3(pick.randf_range(-40.0, 40.0), 0.0, pick.randf_range(-40.0, 40.0)), 6.0, pick.randf_range(-1.5, 1.5))
		var spent := Time.get_ticks_usec() - started
		_edit_total_usec += spent
		_edit_worst_usec = maxi(_edit_worst_usec, spent)
		_edits += 1
	if settings.has("shove-at") and not _shoved and tick >= int(settings["shove-at"]) and session.is_server():
		var entities := session.get_entities()
		if not entities.is_empty():
			_shoved = true
			var body: Node3D = entities[0].get_parent()
			body.position += Vector3(2, 0, 0)
			result["shoved_tick"] = tick
	if settings.has("bonus-at") and not result.has("bonus_tick") and tick >= int(settings["bonus-at"]) and session.is_server():
		var entities := session.get_entities()
		if not entities.is_empty():
			entities[0].get_parent().set("bonus", 1)
			result["bonus_tick"] = tick


## Writes what each pawn did on this tick, the first time this tick happens.
func _on_after_tick(_dt: float, tick: int) -> void:
	var logging_started := Time.get_ticks_usec()
	if tick % 15 == 0:
		_update_summaries()
	if settings.has("no-log"):
		_logging_usec += Time.get_ticks_usec() - logging_started
		return
	for entity: NetworkEntity in session.get_entities():
		var id_key := str(entity.entity_id)
		var body: Node3D = entity.get_parent()
		var at := body.position
		if entity.follows_snapshots():
			if not log_views.has(id_key):
				log_views[id_key] = {}
			if not log_views[id_key].has(str(tick)):
				log_views[id_key][str(tick)] = [session.render_tick, at.x, at.y, at.z, session.get_lead_ticks()]
		else:
			if not log_positions.has(id_key):
				log_positions[id_key] = {}
			if not log_positions[id_key].has(str(tick)):
				log_positions[id_key][str(tick)] = [at.x, at.y, at.z]
	_logging_usec += Time.get_ticks_usec() - logging_started


func _start_measuring() -> void:
	measure_from_tick = driver.tick
	driver.profile_enabled = settings.has("profile")
	driver.reset_profile()
	_loop_total_usec = 0
	_loop_count = 0
	_loop_worst_usec = 0
	_loops_over_budget = 0
	NetTestPawn.path_usec = 0
	NetTestPawn.path_calls = 0
	result["bytes_sent_start"] = session.stats["bytes_sent"]
	result["bytes_received_start"] = session.stats["bytes_received"]
	result["measure_start_usec"] = Time.get_ticks_usec()
	result["corrections_start"] = session.stats["corrections"]
	result["correction_total_start"] = session.stats["correction_total"]
	result["jump_total_start"] = session.stats["jump_total"]
	result["resyncs_start"] = session.stats["resyncs"]
	result["interpolation_underruns_start"] = session.stats["interpolation_underruns"]
	result["missed_inputs_start"] = session.get_missed_inputs()
	session.stats["margin_total"] = 0
	session.stats["margin_reports"] = 0
	session.stats["margin_lowest"] = NetworkSessionSingleton.NO_MARGIN
	session.stats["speed_lowest"] = session.get_tick_factor()
	session.stats["speed_highest"] = session.get_tick_factor()
	for entity: NetworkEntity in session.get_entities():
		entity.missed_inputs = 0


func _capture_summary() -> void:
	result["stats"] = session.stats.duplicate()
	result["tick"] = driver.tick
	result["rtt_ms"] = session.get_rtt_ms()
	result["lead_ticks"] = session.get_lead_ticks()
	# The session may already have ended by now, if the server quit first.
	result["peer"] = result.get("peer_when_joined", session.get_local_peer())
	result["measure_end_usec"] = Time.get_ticks_usec()
	result["measure_from_tick"] = measure_from_tick
	result["fake_lost"] = session.fake.packets_lost
	result["missed_inputs"] = session.get_missed_inputs()
	result["margin_last"] = session.get_input_margin()
	result["features"] = {}
	for feature: String in NetworkSessionSingleton.FEATURES:
		result["features"][feature] = session.is_feature_on(feature)
	result["bursts"] = session.fake.bursts_started + session.fake_in.bursts_started
	result["hitches"] = _hitches
	result["profile"] = driver.profile
	result["physics_average_ms"] = _physics_total_ms / maxi(_physics_samples, 1)
	result["physics_worst_ms"] = _physics_worst_ms
	result["physics_over_budget"] = _physics_over_budget
	result["physics_frames"] = _physics_samples
	var by_second: Array = []
	var seconds: Array = _physics_by_second.keys()
	seconds.sort()
	for second: int in seconds:
		by_second.append(snappedf(float(_physics_by_second[second][0]) / maxi(int(_physics_by_second[second][1]), 1), 0.1))
	result["physics_by_second"] = by_second
	result["active_objects"] = Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)
	result["path_usec"] = NetTestPawn.path_usec
	result["path_calls"] = NetTestPawn.path_calls
	result["nav_tick_average_ms"] = _nav_tick_total_usec / 1000.0 / maxi(_nav_tick_count, 1)
	result["nav_tick_worst_ms"] = _nav_tick_worst_usec / 1000.0
	result["edits"] = _edits
	result["edit_average_ms"] = _edit_total_usec / 1000.0 / maxi(_edits, 1)
	result["edit_worst_ms"] = _edit_worst_usec / 1000.0
	if Engine.has_singleton(&"NavServer"):
		result["nav_stats"] = Engine.get_singleton(&"NavServer").get_stats()
	result["dropped_ticks"] = driver.dropped_ticks
	result["loop_average_ms"] = float(_loop_total_usec) / maxi(_loop_count, 1) / 1000.0
	result["loop_worst_ms"] = _loop_worst_usec / 1000.0
	result["loops_over_budget"] = _loops_over_budget
	result["loop_count"] = _loop_count
	result["spikes"] = session.fake.spikes_started + session.fake_in.spikes_started
	_update_summaries()
	var entities: Array = []
	for entity: NetworkEntity in session.get_entities():
		entities.append(_summaries[entity.entity_id])
	result["entities"] = entities
	result["summaries"] = _summaries.values()


func _update_summaries() -> void:
	for entity: NetworkEntity in session.get_entities():
		var body: Node3D = entity.get_parent()
		_summaries[entity.entity_id] = {
			"id": entity.entity_id, "owner": entity.owner_peer, "role": entity.role, "x": body.position.x, "y": body.position.y, "z": body.position.z,
			"health": body.health, "shots": body.shots_fired, "hits": body.hits_landed, "missed_inputs": entity.missed_inputs,
			"last_input_tick": entity.last_input_tick, "offset": body._correction_offset.length(), "corrections_seen": body.corrections_seen,
			"paths": body.paths_found, "path_failures": body.path_failures, "stuck": body.times_stuck, "walked": body.distance_walked,
			"missing_stretches": body.missing_stretches, "bonus": body.get("bonus"), "total": body.get("total"), "tick": driver.tick,
		}


func _finish() -> void:
	_finished = true
	if not _left:
		_capture_summary()
	result["positions"] = log_positions
	result["views"] = log_views
	var out_path: String = settings.get("out", "user://net_test_output.json")
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var temporary := out_path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(result))
		file.close()
		DirAccess.rename_absolute(temporary, out_path) # so a reader never sees half a file
	session.leave()
	get_tree().quit(0)


## Broken and forged packets. None of this may crash the server or move anything.
func _send_garbage() -> void:
	var multiplayer_api := multiplayer as SceneMultiplayer
	var forged := NetPackets.new_buffer()
	forged.put_u8(NetPackets.Type.INPUT)
	forged.put_u32(1) # the first pawn, which belongs to another client
	forged.put_u32(driver.tick)
	forged.put_u8(1)
	NetPackets.write_list(forged, [Vector3(50, 0, 0), true, true, false, Vector3.FORWARD, 0.0], [StateEncoding.VECTOR3_MM, StateEncoding.RAW, StateEncoding.RAW, StateEncoding.RAW, StateEncoding.VECTOR3_MM, StateEncoding.FLOAT])
	for i in 30:
		multiplayer_api.send_bytes(forged.data_array, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for i in 200:
		var size := rng.randi_range(0, 64)
		var bytes := PackedByteArray()
		bytes.resize(size)
		for b in size:
			bytes[b] = rng.randi_range(0, 255)
		if size > 0 and i % 2 == 0:
			bytes[0] = rng.randi_range(1, NetPackets.Type.SNAPSHOT) # a real packet type with nonsense after it
		multiplayer_api.send_bytes(bytes, 1, MultiplayerPeer.TRANSFER_MODE_RELIABLE)


func _describe(entity: NetworkEntity) -> Dictionary:
	return {"id": entity.entity_id, "owner": entity.owner_peer, "role": entity.role, "local": entity.is_local}


func _read_settings() -> void:
	for argument in OS.get_cmdline_user_args():
		var cleaned := argument.trim_prefix("--")
		var parts := cleaned.split("=", true, 1)
		settings[parts[0]] = parts[1] if parts.size() > 1 else "true"


func _build_terrain() -> void:
	var nav: Object = Engine.get_singleton(&"NavServer")
	nav.configure({"worker_threads": 2})
	nav.add_interest(Vector3.ZERO, 130.0, 160.0, 1)
	var terrain: Node3D = load("res://assets/scripts/navigation/nav_test_terrain.gd").new()
	terrain.set("nav_hooks", NavHooks.new())
	terrain.set("build_collision", true)
	add_child(terrain)
	_terrain = terrain


func _build_arena() -> void:
	add_child(_box(Vector3(30, 1, 30), Vector3(0, -0.5, 0)))
	add_child(_box(Vector3(30, 3, 1), Vector3(0, 1.5, 12)))
	add_child(_box(Vector3(30, 3, 1), Vector3(0, 1.5, -12)))
	add_child(_box(Vector3(1, 3, 30), Vector3(12, 1.5, 0)))
	add_child(_box(Vector3(1, 3, 30), Vector3(-12, 1.5, 0)))


func _box(size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	return body
