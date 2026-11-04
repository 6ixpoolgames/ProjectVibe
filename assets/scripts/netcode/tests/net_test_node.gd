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
##   --no-rewind         server: turns lag compensation off, to compare
##   --lead-seconds=0.3  shooter: how far ahead of the drawn target to aim
##   --predicted         everyone: other pawns are predicted (is_predicted)
##   --ai=2              server: adds this many AI pawns nobody owns
##   --follow            client: remote pawns stand on server data during a rollback, to compare
extends Node

const PAWN_SCENE := "res://assets/scripts/netcode/tests/net_test_pawn.tscn"

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
var _summaries: Dictionary = {}          # entity id -> latest summary, kept after the entity is gone


func _ready() -> void:
	session = get_node("/root/NetworkSession")
	driver = get_node("/root/NetworkTime")
	_read_settings()
	_build_arena()
	session.world_root = self
	session.bind_address = "127.0.0.1"
	session.register_type("pawn", load(PAWN_SCENE))
	session.content_hash_salt = int(settings.get("salt", 0))
	session.lag_compensation_enabled = not settings.has("no-rewind")
	session.default_predicted = settings.has("predicted")
	session.fake.latency_ms = float(settings.get("latency", 0))
	session.fake.jitter_ms = float(settings.get("jitter", 0))
	session.fake.loss = float(settings.get("loss", 0))
	session.fake.set_seed(hash(settings.get("name", "server")))
	NetTestPawn.default_mode = settings.get("mode", "seek")
	NetTestPawn.lead_seconds = float(settings.get("lead-seconds", 0))
	session.joined.connect(func() -> void: result["joined"] = true)
	session.refused.connect(func(reason: String) -> void: result["refused"] = reason)
	session.disconnected.connect(func() -> void: result["disconnected"] = true)
	session.entity_spawned.connect(_on_entity_spawned)
	session.entity_despawned.connect(func(entity_id: int) -> void: result["despawned"].append(entity_id))
	session.player_connected.connect(_on_player_connected)
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


func _process(_delta: float) -> void:
	var elapsed := (Time.get_ticks_usec() - started_usec) / 1000000.0
	if settings.has("delay") and not result.has("join_started") and elapsed >= float(settings["delay"]):
		_join()
	if settings.has("leave-after") and not _left and elapsed >= float(settings["leave-after"]):
		_left = true
		_capture_summary()
		session.leave()
	if settings.has("garbage") and not _garbage_sent and result["joined"] and elapsed >= 2.0:
		_garbage_sent = true
		_send_garbage()
	if measure_from_tick < 0 and elapsed >= 2.0 and driver.active:
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
	var slots := [Vector3(-3, 0.1, 0), Vector3(3, 0.1, 0), Vector3(0, 0.1, -3), Vector3(0, 0.1, 3)]
	session.spawn("pawn", peer, slots[_next_slot % slots.size()])
	_next_slot += 1
	if not _ai_spawned:
		_ai_spawned = true
		for i in int(settings.get("ai", 0)):
			session.spawn("pawn", 0, Vector3(-5 + i, 0.1, 5))


func _on_before_tick(_dt: float, tick: int) -> void:
	if settings.has("shove-at") and not _shoved and tick >= int(settings["shove-at"]) and session.is_server():
		var entities := session.get_entities()
		if not entities.is_empty():
			_shoved = true
			var body: Node3D = entities[0].get_parent()
			body.position += Vector3(2, 0, 0)
			result["shoved_tick"] = tick


## Writes what each pawn did on this tick, the first time this tick happens.
func _on_after_tick(_dt: float, tick: int) -> void:
	if tick % 15 == 0:
		_update_summaries()
	for entity: NetworkEntity in session.get_entities():
		var id_key := str(entity.entity_id)
		var body: Node3D = entity.get_parent()
		var at := body.position
		if entity.role == NetworkEntity.Role.REMOTE_FOLLOWING:
			if not log_views.has(id_key):
				log_views[id_key] = {}
			if not log_views[id_key].has(str(tick)):
				log_views[id_key][str(tick)] = [session.render_tick, at.x, at.y, at.z, session.get_lead_ticks()]
		else:
			if not log_positions.has(id_key):
				log_positions[id_key] = {}
			if not log_positions[id_key].has(str(tick)):
				log_positions[id_key][str(tick)] = [at.x, at.y, at.z]


func _start_measuring() -> void:
	measure_from_tick = driver.tick
	result["bytes_sent_start"] = session.stats["bytes_sent"]
	result["bytes_received_start"] = session.stats["bytes_received"]
	result["measure_start_usec"] = Time.get_ticks_usec()
	result["corrections_start"] = session.stats["corrections"]
	result["correction_total_start"] = session.stats["correction_total"]
	result["jump_total_start"] = session.stats["jump_total"]
	for entity: NetworkEntity in session.get_entities():
		entity.missed_inputs = 0


func _capture_summary() -> void:
	result["stats"] = session.stats.duplicate()
	result["tick"] = driver.tick
	result["rtt_ms"] = session.get_rtt_ms()
	result["lead_ticks"] = session.get_lead_ticks()
	result["peer"] = session.get_local_peer()
	result["measure_end_usec"] = Time.get_ticks_usec()
	result["measure_from_tick"] = measure_from_tick
	result["fake_lost"] = session.fake.packets_lost
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
			"id": entity.entity_id, "owner": entity.owner_peer, "role": entity.role, "x": body.position.x, "z": body.position.z,
			"health": body.health, "shots": body.shots_fired, "hits": body.hits_landed, "missed_inputs": entity.missed_inputs,
			"last_input_tick": entity.last_input_tick, "offset": body._correction_offset.length(),
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
