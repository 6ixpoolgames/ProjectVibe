## Written by Claude (claude-opus-5-5), 2026-11-04: the multiplayer session, stage v0 (netcode spec sections 4, 6, 10, 11).
## Autoload "NetworkSession". Connects machines, spawns entities on all of them, and moves inputs and snapshots between them.
## Everything happens inside NetworkTime's ticks. Nothing here is needed offline: with no session, entities play as single player.
##
## The model is the standard one for competitive action games:
##   - The server is the authority. Clients send it inputs only, never positions or results.
##   - A client runs ahead of the server, so that its input for tick T arrives before the server runs T. Tick numbers mean
##     the same thing everywhere, so "my prediction for tick T" can be compared with "the server's result for tick T".
##   - Your own pawn is predicted: it reacts at once, and when a snapshot says otherwise it's corrected (reconciliation).
##   - Everything else is drawn in the past between snapshots (entity interpolation).
##   - Attacks are checked by the server against what the shooter saw (lag compensation, see LagCompensation.gd).
##
## How to use it:
##   NetworkSession.register_type("pawn", preload("res://pawn.tscn"))  # same types in the same order on every machine
##   NetworkSession.world_root = $Entities
##   NetworkSession.host(port)   or   NetworkSession.join(address, port)
##   # on the server, whenever the game wants something to exist. Claude 2026-11-07: a player joining spawns nothing by itself.
##   NetworkSession.spawn("pawn", peer_id, Vector3(0, 1, 0))
##
## Snapshots are still full, of everything to everyone; delta compression is a later stage.
##
## Time dilation (netcode spec section 4.2, Claude 2026-11-04): the server reports how early each client's inputs have been
## arriving. A client cutting it too fine speeds up at once, going by the last half second. It only slows down again if the
## last 5 seconds have all been safe, so a rough connection keeps the lead it has shown it needs. Its lead settles on the
## smallest that gets inputs there in time, whatever the connection is doing. Only clients dilate. A
## client well behind where its clock says it should be, after a freeze say, jumps straight back instead of slowly catching up,
## because every tick behind is another input arriving too late.
##
## Test tools (Claude 2026-11-07): the fake bad network and switching features while running are in NetDebugModule, an optional child that
## fills packet_filter below. Without one, this does none of that. See docs/TEST_AND_DEBUG_CODE.md.
##
## One tick on a client:   before_tick: apply snapshots (which may roll back), move remote entities ->
##                         the tick's phases -> after_tick: send input
## One tick on the server: before_tick: queue received inputs -> the tick's phases -> after_tick: send snapshots
##
## Rules, checked in tests/net_selftest.gd:
##   - A client with a different content hash is refused with a message saying so.
##   - Input for an entity the sender doesn't own, broken packets of any kind, and too many packets from one client are dropped.
##   - A snapshot older than the newest one seen is dropped. Input for a tick the server has already run is dropped, and the
##     client gets corrected. The server repeats the last input when one is missing, and never rewinds for movement.
##   - A client that joins late gets everything that exists. Entities still owned by a client that leaves are removed. Claude
##     2026-11-07: player_leaving fires first, so something can take back what it wants to keep. PossessionModule does this
##     for a possessed pawn, which stays in the world with no owner.
extends Node
class_name NetworkSessionSingleton

signal hosted
signal joined                               # the client is connected and ticking
signal refused(reason: String)              # couldn't join
signal disconnected                         # the connection ended
signal player_connected(peer: int)          # server: a client passed the handshake
signal player_leaving(peer: int)            # Claude 2026-11-07: server: a client has gone, and what it owns hasn't been removed yet
signal player_left(peer: int)
signal entity_spawned(entity: NetworkEntity)
signal entity_despawned(entity_id: int)
signal entity_owner_changed(entity: NetworkEntity) # Claude 2026-11-07: on every machine

enum Mode { OFFLINE, SERVER, CLIENT }

## The settings the server decides for everyone, so snapshots say what they are.
const SERVER_FEATURES: Array[String] = ["lag_compensation_enabled", "default_predicted"]
## What snapshots say when a client has sent no input lately.
const NO_MARGIN := 32767
## How many recent input packets count, for the quick check that speeds up and the slow one that slows down. At 60 per second,
## half a second and 5 seconds.
const MARGIN_SHORT_WINDOW := 30
const MARGIN_LONG_WINDOW := 300

## Snapshots per second.
@export var snapshot_rate: int = 30
## How far in the past remote entities are drawn. Enough to always have two snapshots to blend between.
@export var interpolation_seconds: float = 0.1
## The most the adaptive version may draw in the past. Also limits how far back a client may claim to see.
@export var max_interpolation_seconds: float = 0.2
## Extra ticks of lead beyond half the round trip, so input still arrives on time when the connection wobbles.
@export var lead_margin_ticks: int = 3
## How far from its lead a client can drift before it jumps back, with dilation off. With dilation on it corrects gently, so
## this only covers things too big for that.
@export var resync_threshold_ticks: int = 4
@export var resync_threshold_with_dilation_ticks: int = 15
## With dilation on, being behind is treated more urgently than being ahead: a tick behind is an input lost.
@export var resync_behind_with_dilation_ticks: int = 6
@export_group("Time dilation")
## Inputs should arrive at least this many ticks early. Below this in the last half second, the client speeds up.
@export var dilation_margin_low_ticks: int = 1
## If even the worst of the last 5 seconds is above this, the client is further ahead than it needs to be, and slows down.
@export var dilation_margin_high_ticks: int = 2
## How much to change speed per tick outside that range. Low enough not to overshoot on a late answer.
@export var dilation_gain: float = 0.02
## Fastest and slowest a client will run. A few percent isn't noticeable.
@export var dilation_max_speedup: float = 0.05
@export var dilation_max_slowdown: float = 0.03
@export_group("Features")
## Your own pawn reacts at once and gets corrected. Off: it waits for the server, so what you do shows up after your ping.
@export var prediction_enabled: bool = true
## Your own pawn is corrected when the server disagrees. Off: it drifts, which shows what prediction alone would do.
@export var reconciliation_enabled: bool = true
## Remote entities are drawn in the past between snapshots. Off: they jump to each newest snapshot.
@export var interpolation_enabled: bool = true
## Remote entities move on from the newest snapshot if nothing newer has arrived. Off: they hold.
@export var extrapolation_enabled: bool = true
## The visible model hides a correction's jump. Off: you see the jump.
@export var correction_smoothing_enabled: bool = true
## During a rollback, remote entities stand on server data rather than where they're drawn. See TickStateComponent.
@export var follow_during_rollback: bool = false
## A client's lead follows its connection. Off: it's set once, and jumps back when it drifts.
@export var time_dilation_enabled: bool = true
## More jitter draws remote entities further in the past. Off: always interpolation_seconds.
@export var adaptive_interpolation_enabled: bool = true
@export_group("")
## How far back lag compensation may go. At 200 ms ping a shooter sees others about 350 ms behind its own tick (round trip,
## margin and interpolation), so this covers that and not much more. Past it, players have to lead their shots.
@export var rewind_cap_seconds: float = 0.35
## Turns lag compensation off, to compare.
@export var lag_compensation_enabled: bool = true
## Project default for is_predicted on every entity. Entities can also turn it on for themselves.
@export var default_predicted: bool = false
## How many inputs each input packet carries, the newest and some past ones, in case some are lost. Each extra one adds about
## 1.7 KB/s of upload. At 3, three packets in a row must be lost for an input to go missing.
@export var input_redundancy: int = 3
## Claude 2026-11-05: snapshots go through NetCodec in C++ when that library is here. Off, or with no library for this platform, they
## go through NetPackets instead. The bytes are the same, so machines of either kind can play together. Takes effect at host or join.
@export var use_native_encoding: bool = true
## Where spawned entities go. Defaults to the current scene.
var world_root: Node = null
## Which address the server listens on. "*" is all of them.
var bind_address: String = "*"
## Claude 2026-11-05: server: the most one client may send, so a broken or hostile client can't bury the server in work. Past these
## its packets are dropped and counted in stats. 0 means no limit. A normal client sends about 60 packets and 6 KB a second for
## each pawn it controls, plus a few pings, so raise these for a game that gives one client over about 30 pawns.
var max_packets_per_second: int = 2000
var max_bytes_per_second: int = 256 * 1024
var max_packet_bytes: int = 64 * 1024
## Claude 2026-11-07: something that can hold packets back on their way out and in, or null, which is normal. It has hold_outgoing(peer,
## bytes, reliable), hold_incoming(peer, bytes), release_due(now_usec) and clear().
var packet_filter: Object = null
## Bytes and packets sent and received, for diagnostics.
var stats := {"bytes_sent": 0, "bytes_received": 0, "packets_sent": 0, "packets_received": 0, "snapshots_received": 0,
		"corrections": 0, "correction_total": 0.0, "correction_worst": 0.0, "jump_total": 0.0, "jump_worst": 0.0, "resyncs": 0,
		"bad_packets": 0, "packets_over_limit": 0, "rejected_inputs": 0, "interpolation_underruns": 0, "margin_total": 0, "margin_reports": 0,
		"margin_lowest": NO_MARGIN, "speed_lowest": 1.0, "speed_highest": 1.0}
## Client: which tick of the server's remote entities are being drawn at. -1 before the first snapshot.
var render_tick: float = -1.0

const HANDSHAKE_TIMEOUT := 5.0
const SAMPLES_BEFORE_TICKING := 6
const PING_INTERVAL_STARTING := 0.05
const PING_INTERVAL := 0.25
## Most packets kept from one peer between ticks, so one client can't crowd out others. A client sends one per pawn per tick, and
## they pile up while the server is frozen, so this has room for 4 pawns through a freeze of half a second.
## Claude 2026-11-05: the project setting that names a build. See content_hash.
const BUILD_ID_SETTING := "project_base/network/build_id"
const HASHED_FILE_TYPES: PackedStringArray = ["gd", "gdc", "tscn", "scn", "tres", "res"]
const MAX_INBOX_PER_PEER := 128
## Most inputs one packet may carry. Fixed, because input_redundancy is a setting each machine has its own copy of.
const MAX_INPUTS_PER_PACKET := 16

var _mode: Mode = Mode.OFFLINE
var _driver: Node = null
var _types: Dictionary = {}          # name -> PackedScene
var _type_order: Array[String] = []
var _entities: Dictionary = {}       # id -> NetworkEntity
var _entity_list: Array[NetworkEntity] = []
var _entity_list_dirty := true
var _next_entity_id := 1
var _peers: Dictionary = {}          # server: peer -> {"welcomed": bool, "connected_at": usec}
var _inbox: Array = []               # [peer, bytes] waiting for the next tick
var _world_channels := {} # Claude 2026-11-07: channel name's hash -> {"receive": Callable, "catch_up": Callable}
var _world_inbox: Array[PackedByteArray] = []
var _client_channels := {} # Claude 2026-11-07: channel name's hash -> Callable(peer, bytes)
var _inbox_counts: Dictionary = {}   # peer -> how many of those are theirs
var _codec: Object = null             # NetCodec, or null to use NetPackets. Claude 2026-11-05
var _cached_hash := 0                # content_hash is costly and a client can ask for it, so it's kept
var _hash_is_cached := false
var _clock := NetClock.new()
var _clock_ready := false
var _next_ping_usec := 0
var _newest_snapshot_tick := -1
var _reconcile_values: Dictionary = {} # entity id -> {"state": Dictionary, "input": Dictionary} for the newest snapshot
var _reconcile_tick := -1
var _input_margin := NO_MARGIN         # client: the worst margin the server last reported
var _missed_inputs := 0                # client: how many of its inputs the server has lacked
var _last_feedback_usec := 0
var _last_snapshot_usec := 0
var _last_snapshot_tick := -1
var _snapshot_jitter_usec := 0.0


func _ready() -> void:
	process_priority = -200
	process_physics_priority = -200
	_driver = get_node_or_null("/root/NetworkTime")
	if _driver == null:
		push_warning("[NetworkSession] no NetworkTime autoload; multiplayer won't run")
		set_process(false)
		return
	_driver.before_tick.connect(_on_before_tick)
	_driver.after_tick.connect(_on_after_tick)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	(multiplayer as SceneMultiplayer).peer_packet.connect(_on_packet)
	(multiplayer as SceneMultiplayer).server_relay = false


func _process(_delta: float) -> void:
	_pump()


func _physics_process(_delta: float) -> void:
	_pump()
	if _mode == Mode.CLIENT and _clock_ready:
		_jump_back_if_drifted()


func _pump() -> void:
	var now := Time.get_ticks_usec()
	if packet_filter:
		packet_filter.release_due(now)
	if _mode == Mode.CLIENT and is_connected_to_session():
		_ping_if_due()
		# No news for a while, in a dropout say: don't keep correcting on an old answer.
		if _clock_ready and now - _last_feedback_usec > 500000:
			_set_tick_factor(1.0)
	if _mode == Mode.SERVER:
		_drop_silent_peers()


# --- Connecting --------------------------------------------------------------------------------

## Adds a type of entity that can be spawned. Every machine must add the same ones.
func register_type(type_name: String, scene: PackedScene) -> void:
	if not _types.has(type_name):
		_type_order.append(type_name)
	_types[type_name] = scene
	_hash_is_cached = false


## Starts a server. Returns OK or an error.
func host(port: int, max_clients: int = 32) -> Error:
	if _driver == null:
		return ERR_UNAVAILABLE # no tick driver, so nothing could run
	leave()
	content_hash() # Claude 2026-11-05: it reads files, so now rather than as a hitch when the first client arrives
	_codec = _make_codec(NetPackets.PROTOCOL_VERSION) # Claude 2026-11-05
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip(bind_address)
	var error := peer.create_server(port, max_clients)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	_mode = Mode.SERVER
	_driver.active = true
	hosted.emit()
	return OK


## Connects to a server. joined or refused follows later. Returns OK or an error.
func join(address: String, port: int) -> Error:
	if _driver == null:
		return ERR_UNAVAILABLE
	leave()
	content_hash() # Claude 2026-11-05: it reads files, so now rather than during the handshake
	_codec = _make_codec(NetPackets.PROTOCOL_VERSION) # Claude 2026-11-05
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, port)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	_mode = Mode.CLIENT
	_driver.active = false # nothing ticks until the clock is set
	return OK


## Ends the session and removes everything it spawned. Safe to call at any time.
func leave() -> void:
	var was_online := _mode != Mode.OFFLINE
	for entity_id: int in _entities.keys():
		_remove_entity(entity_id)
	_entities.clear()
	_entity_list_dirty = true
	_peers.clear()
	_inbox.clear()
	_inbox_counts.clear()
	_reconcile_values.clear()
	_reconcile_tick = -1
	_clock.reset()
	_clock_ready = false
	_newest_snapshot_tick = -1
	render_tick = -1.0
	_next_entity_id = 1
	if packet_filter:
		packet_filter.clear()
	_input_margin = NO_MARGIN
	_missed_inputs = 0
	_last_feedback_usec = 0
	_last_snapshot_usec = 0
	_last_snapshot_tick = -1
	_snapshot_jitter_usec = 0.0
	if _driver:
		_driver.tick_factor = 1.0
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_mode = Mode.OFFLINE
	if _driver:
		_driver.active = true
	if was_online:
		disconnected.emit()


func get_mode() -> Mode:
	return _mode


func is_server() -> bool:
	return _mode == Mode.SERVER


func is_client() -> bool:
	return _mode == Mode.CLIENT


## This machine's peer id. Offline, and on the server, it's 1.
func get_local_peer() -> int:
	return 1 if _mode != Mode.CLIENT else multiplayer.get_unique_id()


func is_connected_to_session() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and not (peer is OfflineMultiplayerPeer) and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## Client: the measured round trip in milliseconds.
func get_rtt_ms() -> float:
	return _clock.get_rtt_usec() / 1000.0


## Client: how many ticks ahead of the server it's actually running.
func get_lead_ticks() -> float:
	if _mode != Mode.CLIENT or not _clock_ready:
		return 0.0
	return _driver.tick - _clock.estimate_server_tick(Time.get_ticks_usec(), _tick_usec())


## Client: how many ticks behind its own tick remote entities are drawn. Attacks send this, for lag compensation.
func get_view_ticks_behind() -> float:
	if _mode != Mode.CLIENT or render_tick < 0.0:
		return 0.0
	return maxf(_driver.tick - render_tick, 0.0)


## Client: how fast its ticks are running compared to normal.
func get_tick_factor() -> float:
	return _driver.tick_factor if _driver else 1.0


## Client: the worst the server has lately seen its inputs arrive, in ticks early. Negative is late. NO_MARGIN if unknown.
func get_input_margin() -> int:
	return _input_margin


## Client: how many of its inputs the server has had to do without.
func get_missed_inputs() -> int:
	return _missed_inputs


## How many ticks behind its own tick a client can believably be drawing others, for lag compensation. It can't be drawing
## anything newer than the snapshot it last acknowledged, and it can't be further behind that than the interpolation limit.
## Acknowledgements only ever move forward, and one older than the rewind cap gets no rewind. A client that deliberately
## acknowledges late still gets through, but that looks exactly like really having high ping, so this can't stop it entirely.
## Offline, the host's own pawn and AI aren't limited.
func limit_view_ticks_behind(peer: int, claimed: float, tick: int) -> float:
	if not _peers.has(peer):
		return claimed
	var acknowledged: int = _peers[peer].get("acknowledged_snapshot", -1)
	var age: int = tick - acknowledged
	if acknowledged < 0 or age > rewind_cap_seconds * _driver.get_tick_rate():
		return 0.0
	var interpolation_limit: float = max_interpolation_seconds * _driver.get_tick_rate()
	return minf(claimed, age + interpolation_limit + 1.0)


## A number that's the same on two machines only if they run the same content. The handshake refuses a client whose number differs.
## Claude 2026-11-05: it used to cover only the entity lists, so two different builds could connect and then disagree on every tick.
## It now also covers the engine build, every physics setting, the tick rate, and the game's own files.
##
## Set the project setting BUILD_ID_SETTING to give a build a name instead of reading its files. That's the normal way for
## a release: stamp the build number when exporting, and only builds with the same number play together. Also use it if
## the same project on different operating systems refuses itself, since line endings can differ.
func content_hash() -> int:
	if _hash_is_cached:
		return _cached_hash
	var parts := PackedStringArray()
	parts.append(str(NetPackets.PROTOCOL_VERSION))
	parts.append(str(TagRegistry.content_hash()))
	# Claude 2026-11-06: navigation now has its own tags, and machines must agree on those bits too.
	parts.append(str(NavTags.content_hash()))
	parts.append(String(Engine.get_version_info()["hash"]))
	parts.append(str(_driver.get_tick_rate() if _driver else 0))
	var setting_names: Array[String] = []
	for property: Dictionary in ProjectSettings.get_property_list():
		if String(property["name"]).begins_with("physics/"):
			setting_names.append(property["name"])
	setting_names.sort()
	for setting_name in setting_names:
		parts.append("%s=%s" % [setting_name, ProjectSettings.get_setting(setting_name)])
	var build_id := str(ProjectSettings.get_setting(BUILD_ID_SETTING, ""))
	if build_id != "":
		parts.append(build_id)
	else:
		_add_file_hashes("res://", parts)
	for type_name in _type_order:
		parts.append(type_name)
		var instance: Node = _types[type_name].instantiate()
		for child in instance.get_children():
			if child is TickStateComponent:
				parts.append_array(child.get_schema())
		instance.free()
	_cached_hash = hash("|".join(parts))
	_hash_is_cached = true
	return _cached_hash


## Claude 2026-11-05: the name and contents of every script, scene and resource in this folder and below. Folders starting with
## a dot are skipped: that's Godot's cache, and git's. An exported game has the same kinds of files, in their packed forms.
func _add_file_hashes(folder: String, parts: PackedStringArray) -> void:
	var files := DirAccess.get_files_at(folder)
	files.sort()
	for file_name in files:
		if HASHED_FILE_TYPES.has(file_name.get_extension()):
			var path := folder.path_join(file_name)
			parts.append(path)
			parts.append(FileAccess.get_md5(path))
	var folders := DirAccess.get_directories_at(folder)
	folders.sort()
	for folder_name in folders:
		if not folder_name.begins_with("."):
			_add_file_hashes(folder.path_join(folder_name), parts)


# --- Entities ----------------------------------------------------------------------------------

## Server or offline: makes an entity on this machine and on every client. owner_peer sends its input; 0 is the server itself.
func spawn(type_name: String, owner_peer: int, at: Variant) -> Node:
	if _mode == Mode.CLIENT:
		push_warning("[NetworkSession] only the server spawns entities")
		return null
	if not _types.has(type_name):
		push_warning("[NetworkSession] unknown entity type '%s'" % type_name)
		return null
	var entity_id := _next_entity_id
	_next_entity_id += 1
	var entity := _create_entity(entity_id, type_name, owner_peer, at)
	if entity and entity.is_replicated and _mode == Mode.SERVER:
		var bytes := _spawn_packet(entity)
		for peer: int in _peers:
			if _peers[peer]["welcomed"]:
				_send(peer, bytes, true)
	return entity.get_parent() if entity else null


## Server or offline: removes an entity everywhere.
func despawn(entity_id: int) -> void:
	if _mode == Mode.CLIENT or not _entities.has(entity_id):
		return
	var replicated: bool = _entities[entity_id].is_replicated
	_remove_entity(entity_id)
	if replicated and _mode == Mode.SERVER:
		var buffer := NetPackets.new_buffer()
		buffer.put_u8(NetPackets.Type.DESPAWN)
		buffer.put_u32(entity_id)
		for peer: int in _peers:
			if _peers[peer]["welcomed"]:
				_send(peer, buffer.data_array, true)


## Claude 2026-11-07: server or offline: gives an entity to another player, or to nobody with 0. Every client hears about it. From
## then on, its input comes from the new owner, and the new owner's machine predicts it.
func set_entity_owner(entity_id: int, new_owner: int) -> void:
	if _mode == Mode.CLIENT or not _entities.has(entity_id):
		return
	var entity: NetworkEntity = _entities[entity_id]
	_apply_owner(entity, new_owner)
	if entity.is_replicated and _mode == Mode.SERVER:
		var buffer := NetPackets.new_buffer()
		buffer.put_u8(NetPackets.Type.OWNER_CHANGED)
		buffer.put_u32(entity_id)
		buffer.put_u32(new_owner)
		for peer: int in _peers:
			if _peers[peer]["welcomed"]:
				_send(peer, buffer.data_array, true)


func _apply_owner(entity: NetworkEntity, new_owner: int) -> void:
	var local := new_owner == get_local_peer() and new_owner != 0
	entity.change_owner(new_owner, local, _role_for(entity, local))
	entity_owner_changed.emit(entity)


func _on_owner_changed(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1 or bytes.size() != 9:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	var entity_id := buffer.get_u32()
	var new_owner := buffer.get_u32()
	var entity: NetworkEntity = _entities.get(entity_id, null)
	if entity:
		_apply_owner(entity, new_owner)


func get_entity(entity_id: int) -> NetworkEntity:
	return _entities.get(entity_id, null)


## Every live entity, in id order. Claude 2026-11-04: the same list each time, rebuilt only when entities come and go, because
## several per-tick paths use it. Read it, don't change it.
func get_entities() -> Array[NetworkEntity]:
	if _entity_list_dirty:
		_entity_list_dirty = false
		var ids: Array = _entities.keys()
		ids.sort()
		_entity_list.clear()
		for entity_id: int in ids:
			var entity: NetworkEntity = _entities[entity_id]
			if is_instance_valid(entity):
				_entity_list.append(entity)
	return _entity_list


func _create_entity(entity_id: int, type_name: String, owner_peer: int, at: Variant) -> NetworkEntity:
	var root: Node = _types[type_name].instantiate()
	root.name = "%s_%d" % [type_name, entity_id]
	var entity: NetworkEntity = null
	for child in root.get_children():
		if child is NetworkEntity:
			entity = child
	if entity == null:
		push_warning("[NetworkSession] entity type '%s' has no NetworkEntity child" % type_name)
		root.free()
		return null
	var local := owner_peer == get_local_peer() and owner_peer != 0
	entity.configure(entity_id, type_name, owner_peer, _role_for(entity, local), local, self)
	if entity.state:
		entity.state.follows_during_rollback = follow_during_rollback
	if at != null and "position" in root:
		root.position = at
	var parent: Node = world_root if is_instance_valid(world_root) else get_tree().current_scene
	_entities[entity_id] = entity
	_entity_list_dirty = true
	# However it goes, even if the game frees it directly, it stops being listed.
	root.tree_exited.connect(_forget_entity.bind(entity_id), CONNECT_ONE_SHOT)
	parent.add_child(root)
	entity_spawned.emit(entity)
	return entity


func _role_for(entity: NetworkEntity, local: bool) -> NetworkEntity.Role:
	if _mode != Mode.CLIENT:
		return NetworkEntity.Role.AUTHORITY
	if local:
		return NetworkEntity.Role.LOCAL_PREDICTED if prediction_enabled else NetworkEntity.Role.LOCAL_UNPREDICTED
	if entity.is_predicted or default_predicted:
		return NetworkEntity.Role.REMOTE_PREDICTED
	return NetworkEntity.Role.REMOTE_FOLLOWING


## A switch changed: every entity works out its role again.
func _refresh_entities() -> void:
	for entity: NetworkEntity in get_entities():
		entity.set_role(_role_for(entity, entity.is_local))
		entity.refresh_input_saving() # Claude 2026-11-05: a server's role doesn't change with default_predicted, but this does
		if entity.state:
			entity.state.follows_during_rollback = follow_during_rollback


func _forget_entity(entity_id: int) -> void:
	_entities.erase(entity_id)
	_entity_list_dirty = true


func _remove_entity(entity_id: int) -> void:
	var entity: NetworkEntity = _entities.get(entity_id, null)
	_forget_entity(entity_id)
	if is_instance_valid(entity):
		var root := entity.get_parent()
		if root.get_parent():
			root.get_parent().remove_child(root)
		root.queue_free()
	entity_despawned.emit(entity_id)


func _spawn_packet(entity: NetworkEntity) -> PackedByteArray:
	var buffer := NetPackets.new_buffer()
	buffer.put_u8(NetPackets.Type.SPAWN)
	buffer.put_u32(entity.entity_id)
	buffer.put_u32(entity.owner_peer)
	NetPackets.write_value(buffer, entity.type_name, StateEncoding.RAW)
	NetPackets.write_value(buffer, entity.get_position_or_null(), StateEncoding.AUTO)
	return buffer.data_array


# --- Sending and receiving ---------------------------------------------------------------------

func _send(peer: int, bytes: PackedByteArray, reliable: bool) -> void:
	stats["bytes_sent"] += bytes.size()
	stats["packets_sent"] += 1
	if packet_filter == null or not packet_filter.hold_outgoing(peer, bytes, reliable):
		_send_now(peer, bytes, reliable)


func _send_now(peer: int, bytes: PackedByteArray, reliable: bool) -> void:
	if not is_connected_to_session():
		return
	if _mode == Mode.SERVER and not multiplayer.get_peers().has(peer):
		return
	var mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	(multiplayer as SceneMultiplayer).send_bytes(bytes, peer, mode)


## Everything arriving comes through here. Connection packets act at once. Inputs and snapshots wait for the next tick, so
## they're applied at a fixed point in the tick's order.
func _on_packet(peer: int, bytes: PackedByteArray) -> void:
	stats["bytes_received"] += bytes.size()
	stats["packets_received"] += 1
	if bytes.is_empty():
		stats["bad_packets"] += 1
		return
	# Claude 2026-11-05: before anything else, so what's over the limit costs next to nothing.
	if _mode == Mode.SERVER and not _within_limits(peer, bytes):
		stats["packets_over_limit"] += 1
		return
	if packet_filter == null or not packet_filter.hold_incoming(peer, bytes):
		_handle_packet(peer, bytes, true)


## Claude 2026-11-05: server: may this client send this packet now? Until it has passed the handshake, it may only send the
## packet that does that. Pings used to be answered straight away with no limit at all, and so did everything else, up to the inbox.
func _within_limits(peer: int, bytes: PackedByteArray) -> bool:
	if not _peers.has(peer):
		return false
	var info: Dictionary = _peers[peer]
	if not info["welcomed"] and int(bytes[0]) != NetPackets.Type.HELLO:
		return false
	if max_packet_bytes > 0 and bytes.size() > max_packet_bytes:
		return false
	var second := Time.get_ticks_msec() / 1000
	if int(info.get("limit_second", -1)) != second:
		info["limit_second"] = second
		info["limit_packets"] = 0
		info["limit_bytes"] = 0
	info["limit_packets"] += 1
	info["limit_bytes"] += bytes.size()
	if max_packets_per_second > 0 and int(info["limit_packets"]) > max_packets_per_second:
		return false
	return max_bytes_per_second <= 0 or int(info["limit_bytes"]) <= max_bytes_per_second


func _handle_packet(peer: int, bytes: PackedByteArray, _reliable: bool) -> void:
	match int(bytes[0]):
		NetPackets.Type.HELLO:
			_on_hello(peer, bytes)
		NetPackets.Type.WELCOME:
			_on_welcome(peer, bytes)
		NetPackets.Type.REFUSED:
			_on_refused(peer, bytes)
		NetPackets.Type.PING:
			_on_ping(peer, bytes)
		NetPackets.Type.PONG:
			_on_pong(peer, bytes)
		NetPackets.Type.SPAWN:
			_on_spawn(peer, bytes)
		NetPackets.Type.DESPAWN:
			_on_despawn(peer, bytes)
		NetPackets.Type.WORLD_MESSAGE:
			_on_world_message(peer, bytes)
		NetPackets.Type.OWNER_CHANGED:
			_on_owner_changed(peer, bytes)
		NetPackets.Type.CLIENT_MESSAGE:
			_on_client_message(peer, bytes)
		NetPackets.Type.INPUT, NetPackets.Type.SNAPSHOT:
			var from_peer: int = _inbox_counts.get(peer, 0)
			if not _driver.active:
				pass
			elif from_peer >= MAX_INBOX_PER_PEER:
				stats["bad_packets"] += 1
			else:
				_inbox_counts[peer] = from_peer + 1
				_inbox.append([peer, bytes])
		_:
			stats["bad_packets"] += 1


# --- Handshake ---------------------------------------------------------------------------------

func _on_peer_connected(peer: int) -> void:
	if _mode == Mode.SERVER:
		_peers[peer] = {"welcomed": false, "connected_at": Time.get_ticks_usec(), "margins": [], "acknowledged_snapshot": -1}


func _on_peer_disconnected(peer: int) -> void:
	if _mode != Mode.SERVER or not _peers.has(peer):
		return
	var welcomed: bool = _peers[peer]["welcomed"]
	_peers.erase(peer)
	# Claude 2026-11-07: after the erase, so nothing is sent to the peer that's gone, and before the loop, so anything given a new
	# owner here isn't removed. A listener can also despawn things, because the loop below only looks at what's left afterwards.
	if welcomed:
		player_leaving.emit(peer)
	for entity_id: int in _entities.keys():
		var entity: NetworkEntity = _entities[entity_id]
		if entity.owner_peer == peer:
			despawn(entity_id)
	if welcomed:
		player_left.emit(peer)


func _on_connected_to_server() -> void:
	var buffer := NetPackets.new_buffer()
	buffer.put_u8(NetPackets.Type.HELLO)
	buffer.put_u32(NetPackets.PROTOCOL_VERSION)
	buffer.put_64(content_hash())
	_send(1, buffer.data_array, true)


func _on_connection_failed() -> void:
	leave()
	refused.emit("could not reach the server")


func _on_server_disconnected() -> void:
	leave()


func _on_hello(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.SERVER or not _peers.has(peer) or _peers[peer]["welcomed"]:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	if not NetPackets.has_bytes(buffer, 12):
		stats["bad_packets"] += 1
		return
	var protocol := buffer.get_u32()
	var their_hash := buffer.get_64()
	if protocol != NetPackets.PROTOCOL_VERSION or their_hash != content_hash():
		var refusal := NetPackets.new_buffer()
		refusal.put_u8(NetPackets.Type.REFUSED)
		refusal.put_utf8_string("version mismatch: this server runs protocol %d, content %d" % [NetPackets.PROTOCOL_VERSION, content_hash()])
		_send(peer, refusal.data_array, true)
		return # they leave when they read it; if they don't, _drop_silent_peers removes them
	_peers[peer]["welcomed"] = true
	var welcome := NetPackets.new_buffer()
	welcome.put_u8(NetPackets.Type.WELCOME)
	welcome.put_u16(_driver.get_tick_rate())
	_send(peer, welcome.data_array, true)
	for entity: NetworkEntity in get_entities():
		if entity.is_replicated:
			_send(peer, _spawn_packet(entity), true)
	_send_world_catch_up(peer) # Claude 2026-11-07
	player_connected.emit(peer)


func _on_welcome(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1 or bytes.size() < 3:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	_driver.tick_rate = buffer.get_u16()
	_clock.reset()
	_next_ping_usec = 0


func _on_refused(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1:
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	var reason := buffer.get_utf8_string()
	leave()
	refused.emit(reason)


## A client that connected but never finished the handshake, or was refused and stayed.
func _drop_silent_peers() -> void:
	var now := Time.get_ticks_usec()
	for peer: int in _peers.keys():
		var info: Dictionary = _peers[peer]
		if not info["welcomed"] and now - int(info["connected_at"]) > int(HANDSHAKE_TIMEOUT * 1000000.0):
			_peers.erase(peer)
			if multiplayer.multiplayer_peer:
				multiplayer.multiplayer_peer.disconnect_peer(peer)


# --- Clock -------------------------------------------------------------------------------------

func _tick_usec() -> float:
	return 1000000.0 / _driver.get_tick_rate()


func _ping_if_due() -> void:
	var now := Time.get_ticks_usec()
	if now < _next_ping_usec:
		return
	_next_ping_usec = now + int((PING_INTERVAL if _clock_ready else PING_INTERVAL_STARTING) * 1000000.0)
	var buffer := NetPackets.new_buffer()
	buffer.put_u8(NetPackets.Type.PING)
	buffer.put_u64(now)
	_send(1, buffer.data_array, false)


func _on_ping(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.SERVER or bytes.size() < 9 or not _peers.has(peer):
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	var pong := NetPackets.new_buffer()
	pong.put_u8(NetPackets.Type.PONG)
	pong.put_u64(buffer.get_u64())
	pong.put_u32(_driver.tick)
	_send(peer, pong.data_array, false)


func _on_pong(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1 or bytes.size() < 13:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	var sent := buffer.get_u64()
	var server_tick := buffer.get_u32()
	var now := Time.get_ticks_usec()
	_clock.add_sample(sent, now, server_tick, _tick_usec())
	if not _clock_ready:
		if _clock.get_sample_count() >= SAMPLES_BEFORE_TICKING:
			_clock_ready = true
			_driver.set_tick(_target_tick(now))
			_driver.active = true
			joined.emit()


## Claude 2026-11-05: checked every frame rather than when a ping returns, so a client that froze is back on time at once. The clock
## goes by the fastest recent ping, so a lag spike doesn't look like falling behind.
func _jump_back_if_drifted() -> void:
	var target := _target_tick(Time.get_ticks_usec())
	var behind: int = target - _driver.tick
	var too_far := absi(behind) > resync_threshold_ticks
	if time_dilation_enabled:
		too_far = behind > resync_behind_with_dilation_ticks or behind < -resync_threshold_with_dilation_ticks
	if too_far:
		stats["resyncs"] += 1
		_driver.set_tick(target)


func _target_tick(now_usec: int) -> int:
	# Claude 2026-11-04: with dilation on, from the fastest recent ping, so a jump during a spike doesn't land on an inflated lead
	# that takes a long time to give back. If that's too little, dilation adds more.
	return roundi(_clock.estimate_server_tick(now_usec, _tick_usec())) + _clock.get_lead_ticks(_tick_usec(), lead_margin_ticks, time_dilation_enabled)


# --- Spawning, on a client ---------------------------------------------------------------------

func _on_spawn(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	if not NetPackets.has_bytes(buffer, 8):
		stats["bad_packets"] += 1
		return
	var entity_id := buffer.get_u32()
	var owner_peer := buffer.get_u32()
	var type_name: Variant = NetPackets.read_value(buffer)
	var at: Variant = NetPackets.read_value(buffer)
	if not (type_name is String) or not _types.has(type_name) or is_same(at, NetPackets.BAD) or _entities.has(entity_id):
		stats["bad_packets"] += 1
		return
	_create_entity(entity_id, type_name, owner_peer, null if is_same(at, TickStateComponent.MISSING) else at)


func _on_despawn(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1 or bytes.size() < 5:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	_remove_entity(buffer.get_u32())


# --- World messages ----------------------------------------------------------------------------
# Claude 2026-11-07: for changes to the world that aren't entities, such as terrain edits. The server sends, in order and reliably,
# and each client gets them at the start of a tick. A system registers a channel by a name that's the same on every machine, with
# a function to receive and, optionally, a function giving what a late joiner needs. A channel nobody has registered is ignored.

## Sets up a channel. receive(bytes) runs on clients. catch_up() runs on the server when a client joins, and returns the bytes
## to send it, or empty for nothing.
func register_world_channel(channel: String, receive: Callable, catch_up: Callable = Callable()) -> void:
	_world_channels[hash(channel)] = {"receive": receive, "catch_up": catch_up}


func unregister_world_channel(channel: String) -> void:
	_world_channels.erase(hash(channel))


## Server: sends bytes to every client on a channel. Does nothing anywhere else.
func send_world_message(channel: String, bytes: PackedByteArray) -> void:
	if _mode != Mode.SERVER:
		return
	var packet := _world_packet(hash(channel), bytes)
	for peer: int in _peers:
		if _peers[peer]["welcomed"]:
			_send(peer, packet, true)


func _world_packet(channel_hash: int, bytes: PackedByteArray) -> PackedByteArray:
	var buffer := NetPackets.new_buffer()
	buffer.put_u8(NetPackets.Type.WORLD_MESSAGE)
	buffer.put_u32(channel_hash)
	buffer.put_data(bytes)
	return buffer.data_array


func _send_world_catch_up(peer: int) -> void:
	for channel_hash: int in _world_channels:
		var catch_up: Callable = _world_channels[channel_hash]["catch_up"]
		if catch_up.is_valid():
			var bytes: PackedByteArray = catch_up.call()
			if not bytes.is_empty():
				_send(peer, _world_packet(channel_hash, bytes), true)


## Only a server sends these, so anyone else sending one is misbehaving.
func _on_world_message(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1 or bytes.size() < 5:
		stats["bad_packets"] += 1
		return
	_world_inbox.append(bytes)


func _deliver_world_messages() -> void:
	if _world_inbox.is_empty():
		return
	var waiting := _world_inbox
	_world_inbox = []
	for bytes: PackedByteArray in waiting:
		var buffer := NetPackets.reader(bytes)
		buffer.get_u8()
		var channel: Dictionary = _world_channels.get(buffer.get_u32(), {})
		if not channel.is_empty() and channel["receive"].is_valid():
			channel["receive"].call(bytes.slice(5))


# --- Client messages ---------------------------------------------------------------------------
# Claude 2026-11-07: the other direction, for a client asking the server for something, so that the session needn't know what. Reliable
# and in order, and handled as they arrive. A client can send anything, so whatever receives these has to check it.

## Sets up a channel. receive(peer, bytes) runs on the server.
func register_client_channel(channel: String, receive: Callable) -> void:
	_client_channels[hash(channel)] = receive


func unregister_client_channel(channel: String) -> void:
	_client_channels.erase(hash(channel))


## Client: sends bytes to the server on a channel. Does nothing anywhere else.
func send_to_server(channel: String, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT:
		return
	var buffer := NetPackets.new_buffer()
	buffer.put_u8(NetPackets.Type.CLIENT_MESSAGE)
	buffer.put_u32(hash(channel))
	buffer.put_data(bytes)
	_send(1, buffer.data_array, true)


func _on_client_message(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.SERVER or not _peers.has(peer) or not _peers[peer]["welcomed"] or bytes.size() < 5:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	var receive: Callable = _client_channels.get(buffer.get_u32(), Callable())
	if receive.is_valid():
		receive.call(peer, bytes.slice(5))
	else:
		stats["bad_packets"] += 1


# --- Once per tick -----------------------------------------------------------------------------

func _on_before_tick(_dt: float, tick: int) -> void:
	if _mode == Mode.OFFLINE:
		return
	var profiling: bool = _driver.profile_enabled
	var mark := Time.get_ticks_usec() if profiling else 0
	_deliver_world_messages() # Claude 2026-11-07: first, so a snapshot after it is read in the world it describes
	var waiting := _inbox
	_inbox = []
	_inbox_counts.clear()
	for item: Array in waiting:
		var bytes: PackedByteArray = item[1]
		if int(bytes[0]) == NetPackets.Type.INPUT:
			_on_input(item[0], bytes, tick)
		else:
			_on_snapshot(item[0], bytes)
	if profiling:
		mark = _profile_part(&"flush", mark)
	if _mode == Mode.CLIENT:
		_reconcile()
		if profiling:
			mark = _profile_part(&"reconcile", mark)
		_move_remote_entities()
		if profiling:
			_profile_part(&"remote", mark)


func _on_after_tick(_dt: float, tick: int) -> void:
	var profiling: bool = _driver.profile_enabled
	var mark := Time.get_ticks_usec() if profiling else 0
	if _mode == Mode.CLIENT:
		_send_inputs(tick)
		if profiling:
			_profile_part(&"send_inputs", mark)
	elif _mode == Mode.SERVER and tick % _snapshot_interval() == 0:
		_send_snapshots(tick)
		if profiling:
			_profile_part(&"send_snapshots", mark)


## Claude 2026-11-05: the network parts of a tick, in the driver's timing record.
func _profile_part(part: StringName, mark: int) -> int:
	var now := Time.get_ticks_usec()
	_driver.profile[part] = int(_driver.profile.get(part, 0)) + now - mark
	return now


func _snapshot_interval() -> int:
	return maxi(1, roundi(float(_driver.get_tick_rate()) / maxi(1, snapshot_rate)))


# --- Inputs ------------------------------------------------------------------------------------

## Client: sends this tick's input for each entity it controls, plus a few past ones in case some were lost.
func _send_inputs(tick: int) -> void:
	for entity: NetworkEntity in get_entities():
		if not entity.is_local or entity.state == null:
			continue
		var buffer := NetPackets.new_buffer()
		buffer.put_u8(NetPackets.Type.INPUT)
		buffer.put_u32(entity.entity_id)
		buffer.put_u32(tick)
		buffer.put_32(_newest_snapshot_tick) # -1 if it hasn't seen one yet
		var count := 0
		for t in range(tick, tick - mini(input_redundancy, MAX_INPUTS_PER_PACKET), -1):
			if entity.state.get_input_values(t).is_empty():
				break
			count += 1
		buffer.put_u8(count)
		var encodings := entity.state.get_input_encodings()
		for i in count:
			NetPackets.write_list(buffer, entity.state.get_input_values(tick - i), encodings)
		_send(1, buffer.data_array, false)


## Server: stores a client's inputs for the ticks they belong to. Only the owner may send them, and they're cleaned first.
func _on_input(peer: int, bytes: PackedByteArray, tick: int) -> void:
	if not _peers.has(peer):
		return # its last packets, still waiting here when it left
	if _mode != Mode.SERVER or not _peers[peer]["welcomed"]:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	if not NetPackets.has_bytes(buffer, 13):
		stats["bad_packets"] += 1
		return
	var entity_id := buffer.get_u32()
	var newest := buffer.get_u32()
	var acknowledged := buffer.get_32()
	var count := buffer.get_u8()
	var entity: NetworkEntity = get_entity(entity_id)
	if entity == null or entity.owner_peer != peer or entity.state == null or count > MAX_INPUTS_PER_PACKET:
		stats["rejected_inputs"] += 1
		return
	# Claude 2026-11-05: the whole packet is read first. A broken one used to count towards the timing that drives time
	# dilation and lag compensation before the break was found.
	var lists: Array = []
	for i in count:
		var values: Variant = NetPackets.read_list(buffer)
		if values == null:
			stats["bad_packets"] += 1
			return
		lists.append(values)
	_note_input_timing(peer, newest, acknowledged, tick)
	for i in count:
		var values: Array = lists[i]
		var input_tick := newest - i
		# Already run: too late, and the server never rewinds for movement. Far ahead: can't be real.
		if input_tick < tick or input_tick >= tick + entity.state.history_size:
			continue
		entity.state.receive_input(input_tick, entity.clean_input(entity.state.input_values_to_dictionary(values)))


## Server: how early this input packet arrived, for time dilation. Only packets bringing something new count: a duplicate, or one
## overtaken on the way, isn't late input, because the server already has what it carries. What a client acknowledges only
## moves forward, and a client can't have seen the future.
func _note_input_timing(peer: int, newest: int, acknowledged: int, tick: int) -> void:
	var info: Dictionary = _peers[peer]
	if newest > int(info.get("newest_input", -1)):
		info["newest_input"] = newest
		var margins: Array = info["margins"]
		margins.append(clampi(newest - tick, -30000, 30000))
		if margins.size() > MARGIN_LONG_WINDOW:
			margins.pop_front()
	if acknowledged <= tick:
		info["acknowledged_snapshot"] = maxi(int(info.get("acknowledged_snapshot", -1)), acknowledged)


# --- Snapshots ---------------------------------------------------------------------------------

## Claude 2026-11-05: NetCodec if it's usable. Falls back to NetPackets if the library is missing, or was built for another
## packet format and would need rebuilding. Asking for it by name means this script still runs on a platform without the library.
func _make_codec(expected_protocol: int) -> Object:
	if not use_native_encoding or not ClassDB.class_exists(&"NetCodec"):
		return null
	var codec: Object = ClassDB.instantiate(&"NetCodec")
	if codec.call(&"get_protocol_version") != expected_protocol:
		push_warning("[NetworkSession] the C++ library uses another packet format; rebuild native/. Using the GDScript encoding for now")
		return null
	return codec


## True if snapshots are going through C++ right now.
func is_using_native_encoding() -> bool:
	return _codec != null


## Server: sends the whole world to every client, with a note for each on how its input is arriving, for time dilation.
func _send_snapshots(tick: int) -> void:
	# Claude 2026-11-05: everything is gathered first and encoded in one call, so C++ is only called into once per snapshot.
	var all_entities := get_entities()
	var entries: Array = []
	entries.resize(all_entities.size() * NetPackets.WORLD_ENTRY_SIZE)
	var at := 0
	for entity: NetworkEntity in all_entities:
		if not entity.is_replicated or entity.state == null:
			continue
		var values := entity.state.get_state_values(tick)
		if values.is_empty():
			continue
		entries[at] = entity.entity_id
		entries[at + 1] = values
		entries[at + 2] = entity.state.get_state_encodings()
		entries[at + 3] = entity.state.get_sync_values()
		entries[at + 4] = entity.state.get_sync_encodings()
		# Other clients predicting this entity need to know what it wants. An empty list keeps it small otherwise.
		entries[at + 5] = entity.state.get_input_values(tick) if (entity.is_predicted or default_predicted) else []
		entries[at + 6] = entity.state.get_input_encodings()
		# Claude 2026-11-05: what save_state returned, so clients can correct it. One byte if there's none.
		entries[at + 7] = entity.state.get_custom_values(tick)
		at += NetPackets.WORLD_ENTRY_SIZE
	entries.resize(at)
	var count := at / NetPackets.WORLD_ENTRY_SIZE
	var world_bytes: PackedByteArray = _codec.write_world(entries) if _codec != null else NetPackets.write_world(entries)
	var server_features := 0
	for i in SERVER_FEATURES.size():
		if get(SERVER_FEATURES[i]):
			server_features |= 1 << i
	var missed_by_peer: Dictionary = {}
	for entity: NetworkEntity in get_entities():
		missed_by_peer[entity.owner_peer] = int(missed_by_peer.get(entity.owner_peer, 0)) + entity.missed_inputs
	for peer: int in _peers:
		if not _peers[peer]["welcomed"]:
			continue
		var packet := NetPackets.new_buffer()
		packet.put_u8(NetPackets.Type.SNAPSHOT)
		packet.put_u32(tick)
		var margins: Array = _peers[peer]["margins"]
		packet.put_16(NO_MARGIN if margins.is_empty() else margins.slice(-MARGIN_SHORT_WINDOW).min())
		# The long check only counts once it covers the whole 5 seconds. A few calm packets prove nothing.
		packet.put_16(margins.min() if margins.size() >= MARGIN_LONG_WINDOW else NO_MARGIN)
		packet.put_u32(missed_by_peer.get(peer, 0))
		packet.put_u8(server_features)
		packet.put_u16(count)
		packet.put_data(world_bytes)
		_send(peer, packet.data_array, false)


## Client: the features the server decides are whatever it says. default_predicted changes roles here, so this matters in a real game too.
func _apply_server_features(mask: int) -> void:
	var changed := false
	for i in SERVER_FEATURES.size():
		var on: bool = mask & (1 << i) != 0
		if get(SERVER_FEATURES[i]) != on:
			set(SERVER_FEATURES[i], on)
			changed = true
	if changed:
		_refresh_entities()


## Client: remote entities store what the snapshot says. Predicted ones keep it aside for _reconcile, newest only.
func _on_snapshot(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	if not NetPackets.has_bytes(buffer, 15):
		stats["bad_packets"] += 1
		return
	var tick := buffer.get_u32()
	var margin := buffer.get_16()
	var margin_long := buffer.get_16()
	var missed := buffer.get_u32()
	var server_features := buffer.get_u8()
	var count := buffer.get_u16()
	if tick <= _newest_snapshot_tick:
		return # arrived out of order; the newer one already replaced it
	# Claude 2026-11-05: the header above stays in GDScript, and the entities are read in one call.
	var parsed: Variant = _codec.read_world(bytes, buffer.get_position(), count) if _codec != null else NetPackets.read_world(buffer, count)
	if parsed == null:
		stats["bad_packets"] += 1
		return
	_note_snapshot_timing(tick)
	_newest_snapshot_tick = tick
	_missed_inputs = missed
	stats["snapshots_received"] += 1
	_update_dilation(margin, margin_long)
	_apply_server_features(server_features)
	_reconcile_values.clear()
	_reconcile_tick = tick
	for item: Array in parsed:
		var entity: NetworkEntity = get_entity(item[0])
		if entity == null or entity.state == null:
			continue # its spawn hasn't arrived yet; the next snapshot covers it
		var values := entity.state.state_values_to_dictionary(item[1])
		entity.state.apply_sync_values(item[2])
		entity.state.receive_authoritative_state(tick, values) # kept for all, so a switch takes effect at once
		if not entity.follows_snapshots():
			_reconcile_values[item[0]] = {"state": values, "input": entity.state.input_values_to_dictionary(item[3]), "custom": item[4]}


## Client: compares predictions with the newest snapshot, and if any are wrong, corrects them and resimulates from there.
func _reconcile() -> void:
	if _reconcile_tick < 0 or not reconciliation_enabled:
		_reconcile_tick = -1
		return
	var tick := _reconcile_tick
	_reconcile_tick = -1
	var corrected := false
	var before: Dictionary = {}
	for entity_id: int in _reconcile_values:
		var entity: NetworkEntity = get_entity(entity_id)
		if entity == null:
			continue
		var values: Dictionary = _reconcile_values[entity_id]["state"]
		var custom: Array = _reconcile_values[entity_id]["custom"]
		if entity.role == NetworkEntity.Role.REMOTE_PREDICTED:
			entity.state.hold_input_from(tick, _reconcile_values[entity_id]["input"])
		if entity.state.matches_state(tick, values, custom):
			continue
		if not entity.state.has_state(tick) and tick >= _driver.tick:
			continue # the client has fallen behind the server; the clock check deals with that
		var predicted: Dictionary = entity.state.get_state(tick)
		if predicted.has("position") and values.has("position"):
			var error: float = (predicted["position"] - values["position"]).length()
			stats["corrections"] += 1
			stats["correction_total"] += error
			stats["correction_worst"] = maxf(stats["correction_worst"], error)
		before[entity_id] = entity.get_position_or_null()
		if entity.state.correct_state(tick, values, custom):
			corrected = true
	if corrected:
		_driver.rollback(tick)
	for entity_id: int in before:
		var entity: NetworkEntity = get_entity(entity_id)
		var was: Variant = before[entity_id]
		var now: Variant = entity.get_position_or_null() if entity else null
		if was != null and now != null:
			var jump: Variant = was - now
			stats["jump_total"] += jump.length()
			stats["jump_worst"] = maxf(stats["jump_worst"], jump.length())
			if correction_smoothing_enabled:
				entity.tell_corrected(jump)
	_reconcile_values.clear()


# --- Interpolation -----------------------------------------------------------------------------

## Client: moves the drawing clock on one tick, keeping it a fixed distance behind the newest snapshot, then places every
## remote entity. It runs slightly fast or slow to catch up rather than jumping, so motion stays smooth.
func _move_remote_entities() -> void:
	if _newest_snapshot_tick < 0:
		return
	var target: float = _newest_snapshot_tick - _interpolation_ticks()
	if not interpolation_enabled:
		render_tick = float(_newest_snapshot_tick)
	elif render_tick < 0.0 or absf(render_tick - target) > 30.0:
		render_tick = target
	else:
		render_tick += 1.0 + clampf((target - render_tick) * 0.1, -0.1, 0.1)
	if interpolation_enabled and render_tick > _newest_snapshot_tick:
		stats["interpolation_underruns"] += 1
	for entity: NetworkEntity in get_entities():
		if entity.follows_snapshots():
			entity.follow_server(render_tick, extrapolation_enabled)


## How far behind the newest snapshot to draw. With jitter, snapshots arrive unevenly, so it draws further back to keep having two
## to blend between.
func _interpolation_ticks() -> float:
	var rate: float = _driver.get_tick_rate()
	var base := interpolation_seconds * rate
	if not adaptive_interpolation_enabled:
		return base
	var jitter_ticks := _snapshot_jitter_usec / _tick_usec()
	return clampf(base + 2.0 * jitter_ticks, base, maxf(base, max_interpolation_seconds * rate))


## How unevenly snapshots are arriving, as a slow average of how far each is from when it was expected.
func _note_snapshot_timing(tick: int) -> void:
	var now := Time.get_ticks_usec()
	if _last_snapshot_usec > 0 and tick > _last_snapshot_tick:
		var expected := (tick - _last_snapshot_tick) * _tick_usec()
		_snapshot_jitter_usec = lerpf(_snapshot_jitter_usec, absf((now - _last_snapshot_usec) - expected), 0.05)
	_last_snapshot_usec = now
	_last_snapshot_tick = tick


# --- Time dilation -----------------------------------------------------------------------------

## Client: the server said how early our inputs have been arriving, at worst, over the last half second and the last 5.
## Too close over the short one: speed up, more the further out it is. Plenty to spare over the whole of the long one: slow down.
## Otherwise, normal speed. The difference is deliberate: being late costs inputs, and being early only costs a little.
func _update_dilation(margin: int, margin_long: int) -> void:
	_last_feedback_usec = Time.get_ticks_usec()
	if margin == NO_MARGIN:
		return
	_input_margin = margin
	stats["margin_total"] += margin
	stats["margin_reports"] += 1
	stats["margin_lowest"] = mini(stats["margin_lowest"], margin)
	if not time_dilation_enabled:
		return
	var error := 0
	if margin < dilation_margin_low_ticks:
		error = margin - dilation_margin_low_ticks
	elif margin_long != NO_MARGIN and margin_long > dilation_margin_high_ticks:
		error = margin_long - dilation_margin_high_ticks
	_set_tick_factor(1.0 - clampf(error * dilation_gain, -dilation_max_speedup, dilation_max_slowdown))


func _set_tick_factor(factor: float) -> void:
	_driver.tick_factor = factor
	stats["speed_lowest"] = minf(stats["speed_lowest"], factor)
	stats["speed_highest"] = maxf(stats["speed_highest"], factor)
