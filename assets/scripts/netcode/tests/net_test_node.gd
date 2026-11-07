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
##   --gravity=20        changes a physics setting on this machine, which should also get it refused
##   --garbage           client: also sends broken packets, and input for a pawn it doesn't own
##   --shove-at=240      server: moves the first pawn 2 m on this tick, which no client can predict
##   --custom            everyone: uses the pawn with custom state (NetTestCustomPawn)
##   --bonus-at=240      server: sets the first pawn's bonus on this tick, which no client can predict
##   --no-rewind         server: turns lag compensation off, to compare
##   --script-encoding   this machine's snapshots go through NetPackets rather than C++
##   --off=a,b  --on=a,b      turn NetworkSession features off or on at the start
##   --switch=5:lag_compensation_enabled:0    turn a feature on or off after this many seconds
##   --allow-debug       server: obey test switches sent by clients
##   --preset=worst      this machine sends and receives through a NetFakeConditions preset
##   --bench-ping=120    sets the round trip through NetTestBench, the same way its keys do
##   --terrain           hills with collision and nav, instead of the flat arena. The same on every machine
##   --streaming         with --terrain: Terrain, loaded around each player by a ChunkStreamer. Claude 2026-11-07
##   --fixed-block         with --terrain: the same Terrain as one fixed block, to compare against --streaming
##   --spread=1000       with either: how far apart each client's pawns start, in metres
##   --load-distance=96 --nav-distance=64 --unload-margin=32   with --streaming: the streaming distances, in metres
##   --ai-loads          with --streaming: the server's AI pawns keep the world loaded too
##   --real-pawn         the tier -1 Pawn with GroundMovement and PawnWalkerBrain, instead of NetTestPawn. Claude 2026-11-07
##   --possess           with --real-pawn: the server gives each client its first pawn through GameMode.possession
##   --look-at=5:1.25    client: after this many seconds, the PlayerController looks this way, in radians
##   --swap-at=8         client: after this many seconds, asks to possess the first pawn nobody owns
##   --ask-for-taken-at=4  client: after this many seconds, asks for a pawn another player has, and for nonsense
##   --despawn-possessed-at=6  server: after this many seconds, removes every pawn a player has
##   --no-server-brain   server: no PawnWalkerBrain, so a pawn only moves if a client's input says so. Claude 2026-11-07
##   --ai-not-possessable  server: pawns nobody owns have possessable off. Claude 2026-11-07
##   --edit-log          with --streaming or --fixed-block: the terrain has a TerrainEditLog
##   --edit-raise        with --edit-every: edits only raise the ground, by more, and nearer the middle
##   --teleport-at=5:600  server: after this many seconds, moves every player's pawns this far along X. Claude 2026-11-07
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
##   --bind=0.0.0.0      server: listen on this address instead of this machine only. Claude 2026-11-05, for testing across operating systems
##   --address=172.18.0.1  client: the server's address, when it isn't on this machine. Claude 2026-11-05
##   --build-id=test     everyone: names the build, so the handshake compares that instead of the game's files. Claude 2026-11-05
extends Node

const PAWN_SCENE := "res://assets/scripts/netcode/tests/net_test_pawn.tscn"
const CUSTOM_PAWN_SCENE := "res://assets/scripts/netcode/tests/net_test_pawn_custom.tscn"
const REAL_PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
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
var _flood_sent := false
const FLOOD_PACKETS := 8000 # Claude 2026-11-05: see _send_some_of_the_flood
const FLOOD_PACKETS_PER_TICK := 200
var _flood_left := 0
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
# Claude 2026-11-07: for --streaming and --fixed-block.
var _streamer: ChunkStreamer = null
var _fixed_interests: Dictionary = {}    # NetworkEntity -> nav interest id, with --fixed-block
var _real_pawns_by_owner := {} # Claude 2026-11-07: owner -> how many of their pawns have spawned here
var _camera_pawn: Pawn = null
var _camera_skip_frames := 0
var _camera_last := Vector3.ZERO
var _camera_worst_jump := 0.0
var _camera_total_jump := 0.0
var _camera_frames := 0
var _spawn_base := Vector3.ZERO
var _players_spawned := 0
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
	session.bind_address = settings.get("bind", "127.0.0.1") # Claude 2026-11-05: see --bind
	if settings.has("build-id"): # Claude 2026-11-05: see --build-id
		ProjectSettings.set_setting(NetworkSessionSingleton.BUILD_ID_SETTING, settings["build-id"])
	var pawn_scene: String = CUSTOM_PAWN_SCENE if settings.has("custom") else PAWN_SCENE
	if settings.has("real-pawn"):
		pawn_scene = REAL_PAWN_SCENE
	session.register_type("pawn", load(pawn_scene))
	session.content_hash_salt = int(settings.get("salt", 0))
	session.use_native_encoding = not settings.has("script-encoding") # Claude 2026-11-05
	if settings.has("gravity"):
		ProjectSettings.set_setting("physics/3d/default_gravity", float(settings["gravity"]))
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
	# Claude 2026-11-07: a record of who got what and when, for reading a run afterwards.
	if settings.has("real-pawn") and GameMode.possession:
		result["possession_log"] = []
		GameMode.possession.possessed.connect(func(peer: int, pawn: Pawn) -> void: result["possession_log"].append(["got", driver.tick, peer, pawn.get_meta(&"network_entity").entity_id]))
		GameMode.possession.released.connect(func(peer: int, _pawn: Pawn) -> void: result["possession_log"].append(["lost", driver.tick, peer]))
		GameMode.possession.refused.connect(func(peer: int, _pawn: Pawn, why: String) -> void: result["possession_log"].append(["refused", driver.tick, peer, why]))
		# Claude 2026-11-07: which pawns were switched off for having no ground.
		result["switched_off"] = []
		if GameMode.ai_activity:
			GameMode.ai_activity.ai_deactivated.connect(func(pawn: Node3D) -> void: result["switched_off"].append(pawn.get_meta(&"network_entity").entity_id))
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
		_move_fixed_interests() # Claude 2026-11-07
	_send_some_of_the_flood() # Claude 2026-11-05


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
	if settings.has("garbage") and not _flood_sent and result["joined"] and elapsed >= 4.0:
		_flood_sent = true
		_flood_left = FLOOD_PACKETS
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
	_run_possession_script(elapsed) # Claude 2026-11-07
	_watch_camera()
	# Claude 2026-11-07: a server moving pawns somewhere new, as a respawn would.
	if settings.has("teleport-at") and not result.has("teleported") and elapsed >= float(String(settings["teleport-at"]).split(":")[0]) and session.is_server():
		result["teleported"] = true
		var distance := float(String(settings["teleport-at"]).split(":")[1])
		for entity: NetworkEntity in session.get_entities():
			if entity.owner_peer != 0:
				var body: Node3D = entity.get_parent()
				var spot: Vector3 = body.position + Vector3(distance, 0.0, 0.0)
				if _terrain is Terrain:
					(_terrain as Terrain).load_chunk((_terrain as Terrain).chunk_of(spot))
					spot.y = (_terrain as Terrain).height_at(spot.x, spot.z) + 0.3
				body.position = spot
	# Claude 2026-11-07: clients quit before the server, and it then unloads their chunks, so this looks while they're still here.
	if settings.has("snapshot-at") and not result.has("streaming_snapshot") and elapsed >= float(settings["snapshot-at"]):
		_capture_streaming_snapshot()
	if not _finished and elapsed >= float(settings.get("seconds", 8)):
		_finish()


func _join() -> void:
	result["join_started"] = true
	session.join(settings.get("address", "127.0.0.1"), int(settings.get("port", 24500))) # Claude 2026-11-05: see --address


func _on_entity_spawned(entity: NetworkEntity) -> void:
	result["spawned"].append(_describe(entity))
	if settings.has("follow") and entity.state:
		entity.state.follows_during_rollback = true
	if settings.has("real-pawn"):
		_set_up_real_pawn(entity) # Claude 2026-11-07
	else:
		_set_up_streaming_for(entity) # Claude 2026-11-07


## Claude 2026-11-07: the real pawn makes its own source. This only sets its distances and gives it something to walk it.
func _set_up_real_pawn(entity: NetworkEntity) -> void:
	var pawn: Pawn = entity.get_parent()
	pawn.streaming_load_distance = float(settings.get("load-distance", 96))
	pawn.streaming_nav_distance = float(settings.get("nav-distance", 64))
	# Claude 2026-11-07: a player's first pawn is the one they possess, which gives it a source. Their other walkers are test scaffolding:
	# nothing would load ground for them, so this turns it on, as a game would have to for pawns like these.
	var earlier_pawns: int = _real_pawns_by_owner.get(entity.owner_peer, 0)
	_real_pawns_by_owner[entity.owner_peer] = earlier_pawns + 1
	if (entity.owner_peer == 0 and settings.has("ai-loads")) or (entity.owner_peer != 0 and earlier_pawns > 0):
		pawn.ai_loads_chunks = true
	if entity.owner_peer == 0 and settings.has("ai-not-possessable"):
		pawn.possessable = false # Claude 2026-11-07
	if pawn._source:
		pawn._source.load_distance = pawn.streaming_load_distance
		pawn._source.nav_distance = pawn.streaming_nav_distance
	if settings.has("no-server-brain") and session.is_server():
		return # Claude 2026-11-07
	var brain := PawnWalkerBrain.new()
	brain.mode = settings.get("mode", "walk") if entity.owner_peer != 0 else settings.get("ai-mode", "idle")
	pawn.add_child(brain)
	if settings.has("fixed-block") and (entity.role == NetworkEntity.Role.AUTHORITY or entity.is_local):
		var at: Vector3 = pawn.position
		_fixed_interests[entity] = Engine.get_singleton(&"NavServer").add_interest(at, float(settings.get("nav-distance", 64)), float(settings.get("nav-distance", 64)) + 32.0, 1)


## Every pawn gets a source on every machine. The source itself works out whether it counts on this machine, which is what
## --streaming is testing. With --fixed-block there's nothing to load, so a pawn only needs nav around it.
func _set_up_streaming_for(entity: NetworkEntity) -> void:
	if _streamer != null:
		var source := StreamingSource.new()
		source.load_distance = float(settings.get("load-distance", 96))
		source.nav_distance = float(settings.get("nav-distance", 64))
		source.active = entity.owner_peer != 0 or settings.has("ai-loads")
		entity.get_parent().add_child(source)
	elif settings.has("fixed-block") and (entity.role == NetworkEntity.Role.AUTHORITY or entity.is_local):
		var at: Vector3 = entity.get_parent().position
		_fixed_interests[entity] = Engine.get_singleton(&"NavServer").add_interest(at, float(settings.get("nav-distance", 64)), float(settings.get("nav-distance", 64)) + 32.0, 1)


func _move_fixed_interests() -> void:
	# GDScript note: no type on the loop variable here. A key may be a freed pawn, and putting one in a typed variable is an error.
	for entity in _fixed_interests.keys():
		if not is_instance_valid(entity):
			Engine.get_singleton(&"NavServer").remove_interest(_fixed_interests[entity])
			_fixed_interests.erase(entity)
		else:
			Engine.get_singleton(&"NavServer").move_interest(_fixed_interests[entity], entity.get_parent().position)


func _on_player_connected(peer: int) -> void:
	# Claude 2026-11-07: each client's pawns start in their own place.
	_spawn_base = Vector3(_players_spawned * float(settings.get("spread", 0)), 0.0, 0.0)
	_players_spawned += 1
	var first_pawn: Node = null
	for i in int(settings.get("walkers", 1)):
		var spawned: Node = session.spawn("pawn", peer, _next_spawn_point())
		if first_pawn == null:
			first_pawn = spawned
	if settings.has("possess") and first_pawn is Pawn:
		GameMode.possession.possess_for(peer, first_pawn)
	if not _ai_spawned:
		_ai_spawned = true
		for i in int(settings.get("ai", 0)):
			session.spawn("pawn", 0, _next_spawn_point())


## Spread out in a growing ring around the middle, starting with the four original spots.
func _next_spawn_point() -> Vector3:
	var slots := [Vector3(-3, 0.1, 0), Vector3(3, 0.1, 0), Vector3(0, 0.1, -3), Vector3(0, 0.1, 3)]
	var index := _next_slot
	_next_slot += 1
	# Claude 2026-11-07: the server has no ground there yet, so it builds that one chunk first to find the height.
	if _terrain is Terrain:
		var angle := index * 2.4
		var radius := 3.0 + sqrt(float(index)) * 3.0
		var spot := _spawn_base + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		var new_terrain: Terrain = _terrain
		new_terrain.load_chunk(new_terrain.chunk_of(spot))
		spot.y = new_terrain.height_at(spot.x, spot.z) + 0.3
		return spot
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
	# Claude 2026-11-07: Terrain's edits come from the server only. The older test terrain edits on every machine, by tick number.
	if edit_every > 0 and _terrain and not (_terrain is Terrain and session.is_client()) and tick % edit_every == 0 and tick >= EDITS_FROM_TICK and tick <= int(settings.get("edit-until", 1000000)):
		var pick := RandomNumberGenerator.new()
		pick.seed = tick
		var started := Time.get_ticks_usec()
		if settings.has("edit-raise"):
			_terrain.call("edit", Vector3(pick.randf_range(-15.0, 15.0), 0.0, pick.randf_range(-15.0, 15.0)), 10.0, pick.randf_range(2.0, 4.0))
		else:
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
	if _terrain is Terrain: # Claude 2026-11-07
		result["chunks_at_measure_start"] = (_terrain as Terrain).get_loaded_chunks().size()
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
	result["native_encoding"] = session.is_using_native_encoding() # Claude 2026-11-05
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
	_capture_streaming() # Claude 2026-11-07
	_capture_possession()
	_update_summaries()
	var entities: Array = []
	for entity: NetworkEntity in session.get_entities():
		entities.append(_summaries[entity.entity_id])
	result["entities"] = entities
	result["summaries"] = _summaries.values()


## What this machine has loaded, with a fingerprint of each chunk's ground, so the test can compare machines.
## Claude 2026-11-07: the steps a --real-pawn test asks for.
func _run_possession_script(elapsed: float) -> void:
	if not settings.has("real-pawn"):
		return
	var possession: PossessionModule = GameMode.possession
	if settings.has("look-at") and possession.controller and not result.has("looked") and elapsed >= float(String(settings["look-at"]).split(":")[0]):
		result["looked"] = true
		possession.controller.look_yaw = float(String(settings["look-at"]).split(":")[1])
		_camera_skip_frames = 5 # a snap of the view isn't a camera jump
	if settings.has("swap-at") and not result.has("swap_asked") and elapsed >= float(settings["swap-at"]):
		result["swap_asked"] = true
		for entity: NetworkEntity in session.get_entities():
			if entity.owner_peer == 0:
				result["swap_target"] = entity.entity_id
				result["swap_tick"] = driver.tick
				possession.possess(entity.get_parent())
				break
	if settings.has("ask-for-taken-at") and not result.has("asked_for_taken") and elapsed >= float(settings["ask-for-taken-at"]):
		result["asked_for_taken"] = true
		for entity: NetworkEntity in session.get_entities():
			if entity.owner_peer != 0 and not entity.is_local:
				result["asked_for"] = entity.entity_id
				possession.possess(entity.get_parent())
				break
		session.request_possession(999999) # no such pawn
	if settings.has("despawn-possessed-at") and not result.has("despawned_possessed") and elapsed >= float(settings["despawn-possessed-at"]) and session.is_server():
		result["despawned_possessed"] = true
		for entity: NetworkEntity in session.get_entities().duplicate():
			if possession.get_peer_of(entity.get_parent()) != 0:
				session.despawn(entity.entity_id)


## Claude 2026-11-07: how far the real camera moves in a frame, and how far it gets from where it should be.
func _watch_camera() -> void:
	if not settings.has("real-pawn") or measure_from_tick < 0 or GameMode.possession == null or GameMode.possession.controller == null:
		return
	var controller := GameMode.possession.controller
	if not is_instance_valid(controller.pawn) or not controller.camera.is_inside_tree():
		return
	var at := controller.camera.global_position
	if _camera_skip_frames > 0:
		_camera_skip_frames -= 1
	elif controller.pawn == _camera_pawn:
		var jump := at.distance_to(_camera_last)
		_camera_worst_jump = maxf(_camera_worst_jump, jump)
		_camera_total_jump += jump
		_camera_frames += 1
	_camera_pawn = controller.pawn
	_camera_last = at


func _capture_possession() -> void:
	if not settings.has("real-pawn"):
		return
	var possession: PossessionModule = GameMode.possession
	var map := {}
	for peer: int in possession._by_peer:
		var pawn: Pawn = possession._by_peer[peer]
		if is_instance_valid(pawn) and pawn.has_meta(&"network_entity"):
			map[str(peer)] = pawn.get_meta(&"network_entity").entity_id
	var controller := possession.controller
	var has_pawn := controller != null and is_instance_valid(controller.pawn)
	result["possession"] = {
		"map": map,
		"my_pawn": controller.pawn.get_meta(&"network_entity").entity_id if has_pawn else 0,
		"camera_in_scene": controller != null and controller.camera.is_inside_tree(),
		"camera_has_view": controller != null and is_instance_valid(controller.camera.get_view()),
		"camera_from_view": controller.camera.global_position.distance_to(controller.camera.get_view().global_position) if controller != null and controller.camera.is_inside_tree() and is_instance_valid(controller.camera.get_view()) else -1.0,
		"camera_worst_jump": _camera_worst_jump,
		"camera_average_jump": _camera_total_jump / maxi(_camera_frames, 1),
		"camera_frames": _camera_frames,
		"arm_count": _count_arms(),
	}


func _count_arms() -> int:
	var count := 0
	for entity: NetworkEntity in session.get_entities():
		var pawn := entity.get_parent() as Pawn
		if pawn and pawn.get_camera_arm():
			count += 1
	return count


func _capture_streaming() -> void:
	if not (_terrain is Terrain):
		return
	var new_terrain: Terrain = _terrain
	var fingerprints := {}
	for key in new_terrain.get_loaded_chunks():
		fingerprints["%d,%d" % [key.x, key.y]] = hash(new_terrain._points[key])
	var numbers := {"chunks": fingerprints, "meshes": new_terrain._mesh_nodes.size(), "collision": new_terrain._collision_nodes.size()}
	for child in new_terrain.get_children():
		if child is TerrainEditLog:
			numbers["edits_in_log"] = (child as TerrainEditLog).get_edit_count()
	if _streamer != null:
		numbers.merge(_streamer.get_stats())
	result["streaming"] = numbers


## Which chunks are loaded right now, and whether each pawn has ground under it right now.
func _capture_streaming_snapshot() -> void:
	if not (_terrain is Terrain):
		return
	var new_terrain: Terrain = _terrain
	var pawns := []
	for entity: NetworkEntity in session.get_entities():
		var at: Vector3 = entity.get_parent().position
		pawns.append({"id": entity.entity_id, "owner": entity.owner_peer, "has_ground": new_terrain.has_chunk(new_terrain.chunk_of(at))})
	result["streaming_snapshot"] = {"chunks": new_terrain.get_loaded_chunks().size(), "pawns": pawns}


## A number from the pawn, or from the brain walking it, or this if neither has it.
func _stat(body: Node, stat: String, otherwise: Variant) -> Variant:
	var brain: Node = body.get_node_or_null("WalkerBrain")
	var value: Variant = brain.get(stat) if brain else null
	if value == null:
		value = body.get(stat)
	return value if value != null else otherwise


func _update_summaries() -> void:
	for entity: NetworkEntity in session.get_entities():
		var body: Node3D = entity.get_parent()
		_summaries[entity.entity_id] = {
			# Claude 2026-11-07: through _stat, because the real pawn and its brain don't have all of these.
			"id": entity.entity_id, "owner": entity.owner_peer, "role": entity.role, "x": body.position.x, "y": body.position.y, "z": body.position.z,
			"health": _stat(body, "health", 0), "shots": _stat(body, "shots_fired", 0), "hits": _stat(body, "hits_landed", 0), "missed_inputs": entity.missed_inputs,
			"last_input_tick": entity.last_input_tick, "offset": body._correction_offset.length(), "corrections_seen": _stat(body, "corrections_seen", 0),
			"paths": _stat(body, "paths_found", 0), "path_failures": _stat(body, "path_failures", 0), "stuck": _stat(body, "times_stuck", 0), "walked": _stat(body, "distance_walked", 0.0),
			"missing_stretches": _stat(body, "missing_stretches", []), "bonus": body.get("bonus"), "total": body.get("total"), "tick": driver.tick,
			"no_ground": _stat(body, "ticks_without_ground", 0), "look_yaw": _stat(body, "look_yaw", 0.0), "simulating": _stat(body, "_simulating", true),
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


## Claude 2026-11-05: far more pings than the server allows one client in a second. Well after _send_garbage, so it uses up a
## different second's budget and those packets still get read. Sent over several ticks: all at once, Linux's default socket buffer
## drops most of them before the game sees them, and the limit never gets tested. 8000 stays over the limit even if the server's
## one-second count restarts halfway through.
func _send_some_of_the_flood() -> void:
	var flood := PackedByteArray([NetPackets.Type.PING, 0, 0, 0, 0, 0, 0, 0, 0])
	var count := mini(_flood_left, FLOOD_PACKETS_PER_TICK)
	for i in count:
		(multiplayer as SceneMultiplayer).send_bytes(flood, 1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	_flood_left -= count


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


## Claude 2026-11-07: Terrain on this machine, either streamed or as a fixed block. The name is the same on every
## machine, because marker ids come from it. Nobody looks at the server, so it builds no meshes, as a real one wouldn't.
func _build_new_terrain() -> void:
	var terrain := Terrain.new()
	terrain.name = "NetworkTerrain"
	if settings.has("edit-log"):
		terrain.add_child(TerrainEditLog.new())
	terrain.nav_hooks = NavHooks.new()
	terrain.build_meshes = settings.get("role", "server") != "server"
	if settings.has("streaming"):
		terrain.build_on_start = false
	else:
		terrain.chunk_radius = 3
	add_child(terrain)
	_terrain = terrain
	NetTestPawn.roam_terrain = terrain
	PawnWalkerBrain.terrain = terrain
	if settings.has("streaming"):
		_streamer = ChunkStreamer.new()
		_streamer.terrain = terrain
		_streamer.unload_margin = float(settings.get("unload-margin", 32))
		add_child(_streamer)
	var game_mode: Node = get_node_or_null("/root/GameMode")
	if game_mode and game_mode.ai_activity:
		game_mode.ai_activity.ai_deactivated.connect(func(_pawn: Node3D) -> void: result["ai_deactivated"] = int(result.get("ai_deactivated", 0)) + 1)
		game_mode.ai_activity.ai_activated.connect(func(_pawn: Node3D) -> void: result["ai_activated"] = int(result.get("ai_activated", 0)) + 1)


func _build_terrain() -> void:
	var nav: Object = Engine.get_singleton(&"NavServer")
	nav.configure({"worker_threads": 2})
	if settings.has("streaming") or settings.has("fixed-block"):
		_build_new_terrain()
		return
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
