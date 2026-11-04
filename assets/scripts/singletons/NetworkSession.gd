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
##   # on the server, when player_connected fires:
##   NetworkSession.spawn("pawn", peer_id, Vector3(0, 1, 0))
##
## Snapshots are still full, of everything to everyone; delta compression is a later stage.
##
## Time dilation (netcode spec section 4.2, Claude 2026-11-04): the server reports how early each client's inputs have been
## arriving. A client cutting it too fine speeds up at once, going by the last half second. It only slows down again if the
## last 5 seconds have all been safe, so a rough connection keeps the lead it has shown it needs. Its lead settles on the
## smallest that gets inputs there in time, whatever the connection is doing. Only clients dilate. Past
## resync_threshold_ticks from where it should be, a client jumps back instead, after a hitch say.
##
## Test switches (Claude 2026-11-04): each feature in FEATURES can be turned off with set_feature, even while running.
## NetTestBench puts them on keys.
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
##   - A client that joins late gets everything that exists. Entities owned by a client that leaves are removed.
extends Node
class_name NetworkSessionSingleton

signal hosted
signal joined                               # the client is connected and ticking
signal refused(reason: String)              # couldn't join
signal disconnected                         # the connection ended
signal player_connected(peer: int)          # server: a client passed the handshake
signal player_left(peer: int)
signal entity_spawned(entity: NetworkEntity)
signal entity_despawned(entity_id: int)

enum Mode { OFFLINE, SERVER, CLIENT }

## Every switch set_feature understands, in the order NetTestBench shows them.
const FEATURES: Array[String] = ["prediction_enabled", "reconciliation_enabled", "interpolation_enabled", "extrapolation_enabled", "correction_smoothing_enabled", "lag_compensation_enabled", "default_predicted", "follow_during_rollback", "time_dilation_enabled", "adaptive_interpolation_enabled"]
## The ones the server decides or needs to know about. A client's switch is also sent to the server, for testing.
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
## Where spawned entities go. Defaults to the current scene.
var world_root: Node = null
## Changes the content hash, to test the refusal.
var content_hash_salt: int = 0
## Which address the server listens on. "*" is all of them.
var bind_address: String = "*"
## Pretend the network is bad, for testing. See NetFakeConditions.gd. One for what this machine sends, one for what it receives.
var fake := NetFakeConditions.new()
var fake_in := NetFakeConditions.new()
## Server: obey test switches sent by clients. Also needs a debug build, so a release game can never turn this on.
var allow_debug_commands: bool = false
## Bytes and packets sent and received, for diagnostics.
var stats := {"bytes_sent": 0, "bytes_received": 0, "packets_sent": 0, "packets_received": 0, "snapshots_received": 0,
		"corrections": 0, "correction_total": 0.0, "correction_worst": 0.0, "jump_total": 0.0, "jump_worst": 0.0, "resyncs": 0,
		"bad_packets": 0, "rejected_inputs": 0, "interpolation_underruns": 0, "margin_total": 0, "margin_reports": 0,
		"margin_lowest": NO_MARGIN, "speed_lowest": 1.0, "speed_highest": 1.0}
## Client: which tick of the server's remote entities are being drawn at. -1 before the first snapshot.
var render_tick: float = -1.0

const HANDSHAKE_TIMEOUT := 5.0
const SAMPLES_BEFORE_TICKING := 6
const PING_INTERVAL_STARTING := 0.05
const PING_INTERVAL := 0.25
## Most packets kept from one peer between ticks. A normal client sends one or two; the limit stops one client crowding out others.
const MAX_INBOX_PER_PEER := 32
## Most inputs one packet may carry. Fixed, because input_redundancy is a setting each machine has its own copy of.
const MAX_INPUTS_PER_PACKET := 16

var _mode: Mode = Mode.OFFLINE
var _driver: Node = null
var _types: Dictionary = {}          # name -> PackedScene
var _type_order: Array[String] = []
var _entities: Dictionary = {}       # id -> NetworkEntity
var _next_entity_id := 1
var _peers: Dictionary = {}          # server: peer -> {"welcomed": bool, "connected_at": usec}
var _inbox: Array = []               # [peer, bytes] waiting for the next tick
var _inbox_counts: Dictionary = {}   # peer -> how many of those are theirs
var _cached_hash := 0                # content_hash is costly and a client can ask for it, so it's kept
var _cached_hash_salt := -1
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


func _pump() -> void:
	var now := Time.get_ticks_usec()
	fake.release_due(now, _send_now)
	fake_in.release_due(now, _handle_packet)
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
	fake.clear()
	fake_in.clear()
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


func is_feature_on(feature: String) -> bool:
	return FEATURES.has(feature) and get(feature)


## Turns a feature on or off, even while running. See FEATURES.
func set_feature(feature: String, on: bool) -> void:
	if not FEATURES.has(feature):
		push_warning("[NetworkSession] no feature called '%s'" % feature)
		return
	set(feature, on)
	_refresh_entities()
	if not time_dilation_enabled and _driver:
		_set_tick_factor(1.0)
	if _mode == Mode.CLIENT and SERVER_FEATURES.has(feature):
		var buffer := NetPackets.new_buffer()
		buffer.put_u8(NetPackets.Type.DEBUG_SWITCH)
		NetPackets.write_value(buffer, feature, StateEncoding.RAW)
		NetPackets.write_value(buffer, on, StateEncoding.RAW)
		_send(1, buffer.data_array, true)


## How many ticks behind its own tick a client can believably be drawing others, for lag compensation. It can't be drawing
## anything newer than the snapshot it last acknowledged, and it can't be further behind that than the interpolation limit.
## A client could still fake old acknowledgements, which looks the same as really having high ping. Offline, the host's own
## pawn and AI aren't limited.
func limit_view_ticks_behind(peer: int, claimed: float, tick: int) -> float:
	if not _peers.has(peer):
		return claimed
	var acknowledged: int = _peers[peer].get("acknowledged_snapshot", -1)
	if acknowledged < 0:
		return 0.0
	var interpolation_limit: float = max_interpolation_seconds * _driver.get_tick_rate()
	return minf(claimed, (tick - acknowledged) + interpolation_limit + 1.0)


## A number that's the same on two machines only if they run the same content.
func content_hash() -> int:
	if _hash_is_cached and _cached_hash_salt == content_hash_salt:
		return _cached_hash
	var parts := PackedStringArray()
	parts.append(str(NetPackets.PROTOCOL_VERSION))
	parts.append(str(TagRegistry.content_hash()))
	parts.append(str(content_hash_salt))
	for type_name in _type_order:
		parts.append(type_name)
		var instance: Node = _types[type_name].instantiate()
		for child in instance.get_children():
			if child is TickStateComponent:
				parts.append_array(child.get_schema())
		instance.free()
	_cached_hash = hash("|".join(parts))
	_cached_hash_salt = content_hash_salt
	_hash_is_cached = true
	return _cached_hash


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


func get_entity(entity_id: int) -> NetworkEntity:
	return _entities.get(entity_id, null)


## Every live entity, in id order.
func get_entities() -> Array[NetworkEntity]:
	var ids: Array = _entities.keys()
	ids.sort()
	var out: Array[NetworkEntity] = []
	for entity_id: int in ids:
		var entity: NetworkEntity = _entities[entity_id]
		if is_instance_valid(entity):
			out.append(entity)
	return out


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
	parent.add_child(root)
	_entities[entity_id] = entity
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
		if entity.state:
			entity.state.follows_during_rollback = follow_during_rollback


func _remove_entity(entity_id: int) -> void:
	var entity: NetworkEntity = _entities.get(entity_id, null)
	_entities.erase(entity_id)
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
	if fake.is_active():
		fake.submit(peer, bytes, reliable, Time.get_ticks_usec())
	else:
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
	if fake_in.is_active():
		fake_in.submit(peer, bytes, _is_reliable_type(int(bytes[0])), Time.get_ticks_usec())
	else:
		_handle_packet(peer, bytes, true)


func _is_reliable_type(type: int) -> bool:
	return type != NetPackets.Type.INPUT and type != NetPackets.Type.SNAPSHOT and type != NetPackets.Type.PING and type != NetPackets.Type.PONG


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
		NetPackets.Type.DEBUG_SWITCH:
			_on_debug_switch(peer, bytes)
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


## Server: a client's test switch. Refused unless this is a debug build and the game allows it, and only for SERVER_FEATURES.
func _on_debug_switch(_peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.SERVER or not allow_debug_commands or not OS.is_debug_build():
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	var feature: Variant = NetPackets.read_value(buffer)
	var on: Variant = NetPackets.read_value(buffer)
	if feature is String and SERVER_FEATURES.has(feature) and on is bool:
		set(feature, on)
	else:
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
	elif absf(_driver.tick - _target_tick(now)) > (resync_threshold_with_dilation_ticks if time_dilation_enabled else resync_threshold_ticks):
		stats["resyncs"] += 1
		_driver.set_tick(_target_tick(now))


func _target_tick(now_usec: int) -> int:
	return roundi(_clock.estimate_server_tick(now_usec, _tick_usec())) + _clock.get_lead_ticks(_tick_usec(), lead_margin_ticks)


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


# --- Once per tick -----------------------------------------------------------------------------

func _on_before_tick(_dt: float, tick: int) -> void:
	if _mode == Mode.OFFLINE:
		return
	var waiting := _inbox
	_inbox = []
	_inbox_counts.clear()
	for item: Array in waiting:
		var bytes: PackedByteArray = item[1]
		if int(bytes[0]) == NetPackets.Type.INPUT:
			_on_input(item[0], bytes, tick)
		else:
			_on_snapshot(item[0], bytes)
	if _mode == Mode.CLIENT:
		_reconcile()
		_move_remote_entities()


func _on_after_tick(_dt: float, tick: int) -> void:
	if _mode == Mode.CLIENT:
		_send_inputs(tick)
	elif _mode == Mode.SERVER and tick % _snapshot_interval() == 0:
		_send_snapshots(tick)


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
		buffer.put_u32(maxi(_newest_snapshot_tick, 0))
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
	if _mode != Mode.SERVER or not _peers.has(peer) or not _peers[peer]["welcomed"]:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	if not NetPackets.has_bytes(buffer, 13):
		stats["bad_packets"] += 1
		return
	var entity_id := buffer.get_u32()
	var newest := buffer.get_u32()
	var acknowledged := buffer.get_u32()
	var count := buffer.get_u8()
	var entity: NetworkEntity = get_entity(entity_id)
	if entity == null or entity.owner_peer != peer or entity.state == null or count > MAX_INPUTS_PER_PACKET:
		stats["rejected_inputs"] += 1
		return
	# How early this input arrived, for time dilation. A client can't have seen the future.
	var margins: Array = _peers[peer]["margins"]
	margins.append(clampi(newest - tick, -30000, 30000))
	if margins.size() > MARGIN_LONG_WINDOW:
		margins.pop_front()
	if acknowledged <= tick:
		_peers[peer]["acknowledged_snapshot"] = acknowledged
	for i in count:
		var values: Variant = NetPackets.read_list(buffer)
		if values == null:
			stats["bad_packets"] += 1
			return
		var input_tick := newest - i
		# Already run: too late, and the server never rewinds for movement. Far ahead: can't be real.
		if input_tick < tick or input_tick >= tick + entity.state.history_size:
			continue
		entity.state.receive_input(input_tick, entity.clean_input(entity.state.input_values_to_dictionary(values)))


# --- Snapshots ---------------------------------------------------------------------------------

## Server: sends the whole world to every client, with a note for each on how its input is arriving, for time dilation.
func _send_snapshots(tick: int) -> void:
	var world := NetPackets.new_buffer()
	var count := 0
	for entity: NetworkEntity in get_entities():
		if not entity.is_replicated or entity.state == null:
			continue
		var values := entity.state.get_state_values(tick)
		if values.is_empty():
			continue
		world.put_u32(entity.entity_id)
		NetPackets.write_list(world, values, entity.state.get_state_encodings())
		NetPackets.write_list(world, entity.state.get_sync_values(), entity.state.get_sync_encodings())
		# Other clients predicting this entity need to know what it wants. An empty list keeps it small otherwise.
		var input_values: Array = entity.state.get_input_values(tick) if (entity.is_predicted or default_predicted) else []
		NetPackets.write_list(world, input_values, entity.state.get_input_encodings())
		count += 1
	var world_bytes := world.data_array
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
		packet.put_16(NO_MARGIN if margins.is_empty() else margins.min())
		packet.put_u32(missed_by_peer.get(peer, 0))
		packet.put_u16(count)
		packet.put_data(world_bytes)
		_send(peer, packet.data_array, false)


## Client: remote entities store what the snapshot says. Predicted ones keep it aside for _reconcile, newest only.
func _on_snapshot(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	if not NetPackets.has_bytes(buffer, 14):
		stats["bad_packets"] += 1
		return
	var tick := buffer.get_u32()
	var margin := buffer.get_16()
	var margin_long := buffer.get_16()
	var missed := buffer.get_u32()
	var count := buffer.get_u16()
	if tick <= _newest_snapshot_tick:
		return # arrived out of order; the newer one already replaced it
	var parsed: Array = []
	for i in count:
		if not NetPackets.has_bytes(buffer, 4):
			stats["bad_packets"] += 1
			return
		var entity_id := buffer.get_u32()
		var state_values: Variant = NetPackets.read_list(buffer)
		var sync_values: Variant = NetPackets.read_list(buffer)
		var input_values: Variant = NetPackets.read_list(buffer)
		if state_values == null or sync_values == null or input_values == null:
			stats["bad_packets"] += 1
			return
		parsed.append([entity_id, state_values, sync_values, input_values])
	_note_snapshot_timing(tick)
	_newest_snapshot_tick = tick
	_missed_inputs = missed
	stats["snapshots_received"] += 1
	_update_dilation(margin, margin_long)
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
			_reconcile_values[item[0]] = {"state": values, "input": entity.state.input_values_to_dictionary(item[3])}


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
		if entity.role == NetworkEntity.Role.REMOTE_PREDICTED:
			entity.state.hold_input_from(tick, _reconcile_values[entity_id]["input"])
		if entity.state.matches_state(tick, values):
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
		if entity.state.correct_state(tick, values):
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
	elif margin_long > dilation_margin_high_ticks:
		error = margin_long - dilation_margin_high_ticks
	_set_tick_factor(1.0 - clampf(error * dilation_gain, -dilation_max_speedup, dilation_max_slowdown))


func _set_tick_factor(factor: float) -> void:
	_driver.tick_factor = factor
	stats["speed_lowest"] = minf(stats["speed_lowest"], factor)
	stats["speed_highest"] = maxf(stats["speed_highest"], factor)
