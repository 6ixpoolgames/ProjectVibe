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
## Stage v0 means: full snapshots of everything to everyone, a fixed lead, and no time dilation. If a client drifts well
## away from its lead, after a hitch say, it jumps back. Dilation and delta compression are stage v1.
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

## Snapshots per second.
@export var snapshot_rate: int = 30
## How far in the past remote entities are drawn. Enough to always have two snapshots to blend between.
@export var interpolation_seconds: float = 0.1
## Extra ticks of lead beyond half the round trip, so input still arrives on time when the connection wobbles.
@export var lead_margin_ticks: int = 3
## How far from its lead a client can drift before it jumps back.
@export var resync_threshold_ticks: int = 4
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
## Pretend the network is bad, for testing. See NetFakeConditions.gd.
var fake := NetFakeConditions.new()
## Bytes and packets sent and received, for diagnostics.
var stats := {"bytes_sent": 0, "bytes_received": 0, "packets_sent": 0, "packets_received": 0, "snapshots_received": 0,
		"corrections": 0, "correction_total": 0.0, "correction_worst": 0.0, "jump_total": 0.0, "jump_worst": 0.0, "resyncs": 0,
		"bad_packets": 0, "rejected_inputs": 0}
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
	fake.release_due(Time.get_ticks_usec(), _send_now)
	if _mode == Mode.CLIENT and is_connected_to_session():
		_ping_if_due()
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
	var new_role := NetworkEntity.Role.AUTHORITY
	if _mode == Mode.CLIENT:
		if local:
			new_role = NetworkEntity.Role.LOCAL_PREDICTED
		elif entity.is_predicted or default_predicted:
			new_role = NetworkEntity.Role.REMOTE_PREDICTED
		else:
			new_role = NetworkEntity.Role.REMOTE_FOLLOWING
	entity.configure(entity_id, type_name, owner_peer, new_role, local, self)
	if at != null and "position" in root:
		root.position = at
	var parent: Node = world_root if is_instance_valid(world_root) else get_tree().current_scene
	parent.add_child(root)
	_entities[entity_id] = entity
	entity_spawned.emit(entity)
	return entity


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
		_peers[peer] = {"welcomed": false, "connected_at": Time.get_ticks_usec()}


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
	elif absf(_driver.tick - _target_tick(now)) > resync_threshold_ticks:
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
	if not NetPackets.has_bytes(buffer, 9):
		stats["bad_packets"] += 1
		return
	var entity_id := buffer.get_u32()
	var newest := buffer.get_u32()
	var count := buffer.get_u8()
	var entity: NetworkEntity = get_entity(entity_id)
	if entity == null or entity.owner_peer != peer or entity.state == null or count > MAX_INPUTS_PER_PACKET:
		stats["rejected_inputs"] += 1
		return
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

## Server: sends the whole world to every client. Stage v0 sends the same packet to all of them. Reporting each client's
## input timing, which dynamic time dilation needs, comes with that (netcode spec section 11.3).
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
	var packet := NetPackets.new_buffer()
	packet.put_u8(NetPackets.Type.SNAPSHOT)
	packet.put_u32(tick)
	packet.put_u16(count)
	packet.put_data(world.data_array)
	var bytes := packet.data_array
	for peer: int in _peers:
		if _peers[peer]["welcomed"]:
			_send(peer, bytes, false)


## Client: remote entities store what the snapshot says. Predicted ones keep it aside for _reconcile, newest only.
func _on_snapshot(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	if not NetPackets.has_bytes(buffer, 6):
		stats["bad_packets"] += 1
		return
	var tick := buffer.get_u32()
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
	_newest_snapshot_tick = tick
	stats["snapshots_received"] += 1
	_reconcile_values.clear()
	_reconcile_tick = tick
	for item: Array in parsed:
		var entity: NetworkEntity = get_entity(item[0])
		if entity == null or entity.state == null:
			continue # its spawn hasn't arrived yet; the next snapshot covers it
		var values := entity.state.state_values_to_dictionary(item[1])
		entity.state.apply_sync_values(item[2])
		if entity.role == NetworkEntity.Role.REMOTE_FOLLOWING:
			entity.state.receive_authoritative_state(tick, values)
		else:
			_reconcile_values[item[0]] = {"state": values, "input": entity.state.input_values_to_dictionary(item[3])}


## Client: compares predictions with the newest snapshot, and if any are wrong, corrects them and resimulates from there.
func _reconcile() -> void:
	if _reconcile_tick < 0:
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
			entity.tell_corrected(jump)
	_reconcile_values.clear()


# --- Interpolation -----------------------------------------------------------------------------

## Client: moves the drawing clock on one tick, keeping it a fixed distance behind the newest snapshot, then places every
## remote entity. It runs slightly fast or slow to catch up rather than jumping, so motion stays smooth.
func _move_remote_entities() -> void:
	if _newest_snapshot_tick < 0:
		return
	var target: float = _newest_snapshot_tick - interpolation_seconds * _driver.get_tick_rate()
	if render_tick < 0.0 or absf(render_tick - target) > 30.0:
		render_tick = target
	else:
		render_tick += 1.0 + clampf((target - render_tick) * 0.1, -0.1, 0.1)
	for entity: NetworkEntity in get_entities():
		if entity.role == NetworkEntity.Role.REMOTE_FOLLOWING:
			entity.follow_server(render_tick)
