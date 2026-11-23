# Written by Claude (claude-opus-5-5), 2026-11-04. History: netcode/CHANGELOG.md.
## The multiplayer session (autoload "NetworkSession"): connects machines, spawns entities on all of them, and moves inputs and
## snapshots between them. Offline it does nothing and entities play as single player.
##
## The standard model for competitive action games: the server is the authority and clients send it inputs only; a client runs ahead so
## its input for tick T arrives before the server runs T; its own pawn is predicted and corrected (reconciliation); everything else is
## drawn in the past between snapshots (interpolation); the server checks attacks (LagCompensation). It all runs inside TickDriver's
## ticks. Non-entity systems, such as terrain edits, send their own messages through world and client channels.
## [codeblock]
## NetworkSession.register_type("pawn", preload("res://pawn.tscn"))  # same types in the same order on every machine
## NetworkSession.world_root = $Entities
## NetworkSession.host(port)   # or NetworkSession.join(address, port)
## NetworkSession.spawn("pawn", peer_id, Vector3(0, 1, 0))   # on the server; a joining player spawns nothing by itself
## [/codeblock]
## Design: netcode spec 4, 6, 10, 11. Tick order, packet formats, time dilation and the rules: singletons/README.md.
extends Node
class_name NetworkSessionSingleton
# REFACTOR: one class doing many jobs, about 2000 lines: the connection and handshake, the entity list and spawning, the clock and
# time dilation, inputs, encoding and acknowledging snapshots (deltas, parts), reconciliation, interpolation, world and client
# channels, and connection statistics. Helpers with one job each (a snapshot sender and receiver, a clock, the channels) would be
# easier to read, test and extend; the autoload would keep the public API (reusable, extensible). See CHANGELOG.md.

## Server: hosting has started.
signal hosted
## Client: connected, past the handshake, and ticking.
signal joined
## Client: couldn't join, and why.
signal refused(reason: String)
## The connection ended; [signal connection_ended] was sent just before, with the reason.
signal disconnected
## Server: a client passed the handshake.
signal player_connected(peer: int)
## Server: a client has gone, and what it owns hasn't been removed yet, so a listener can keep something by giving it a new owner.
signal player_leaving(peer: int)
## Server: a client has gone, and what it owned has been removed.
signal player_left(peer: int)
## An entity was made on this machine, by spawn or a spawn packet.
signal entity_spawned(entity: NetworkEntity)
## An entity was removed on this machine.
signal entity_despawned(entity_id: int)
## An entity has a new owner, on every machine.
signal entity_owner_changed(entity: NetworkEntity)
## A connection ended, and why, for diagnostics. peer is 1 on a client (sent just before [signal disconnected]); on a server, once per client
## that goes, and 0 when the server stops. details: seconds_connected, seconds_since_heard, rtt_ms, loss_percent (-1: never measured).
signal connection_ended(peer: int, reason: String, details: Dictionary)

## Whether this machine is offline, a server, or a client.
enum Mode { OFFLINE, SERVER, CLIENT }

## The settings the server decides for everyone, so snapshots say what they are.
const SERVER_FEATURES: Array[String] = ["lag_compensation_enabled", "default_predicted"]
## What snapshots say when a client has sent no input lately.
const NO_MARGIN := 32767
## How many recent input packets count for the quick check that speeds up: half a second at 60 a second.
const MARGIN_SHORT_WINDOW := 30
## How many recent input packets count for the slow check that slows down: 5 seconds at 60 a second.
const MARGIN_LONG_WINDOW := 300

## Snapshots per second.
@export var snapshot_rate: int = 30
## How far in the past remote entities are drawn. Enough to always have two snapshots to blend between.
@export var interpolation_seconds: float = 0.1
## The most the adaptive version may draw in the past. Also limits how far back a client may claim to see.
@export var max_interpolation_seconds: float = 0.2
## Extra ticks of lead beyond half the round trip, so input still arrives on time when the connection wobbles.
@export var lead_margin_ticks: int = 3
## How far from its lead a client can drift before it jumps back, with dilation off.
@export var resync_threshold_ticks: int = 4
## How far ahead of its lead a client can drift before it jumps back, with dilation on. Dilation corrects gently, so this only
## covers things too big for that.
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
## The fastest a client will run, as a fraction above normal speed. A few percent isn't noticeable.
@export var dilation_max_speedup: float = 0.05
## The slowest a client will run, as a fraction below normal speed.
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
## Snapshots send each entity's changes since its baseline for that client: the newest snapshot whose part holding it the client
## acknowledged reading (per-part ACKs), instead of everything. Off: every entity in full, to compare.
@export var delta_snapshots_enabled: bool = true
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
## On the server, when a client's input goes missing, the last one repeats in full for this many ticks. Most losses are a tick or
## two. An entity can use its own number instead; Pawn has missing_input_hold_ticks for that.
@export var missing_input_hold_ticks: int = 3
## Then its direction fades to nothing over this many ticks, so a pawn whose player lost connection doesn't walk on forever. Pawn
## can override it with missing_input_fade_ticks.
@export var missing_input_fade_ticks: int = 6
## Snapshots go through NetCodec in C++ when that library is here. Off, or with no library for this platform, they go through
## NetPackets instead. The bytes are the same, so machines of either kind can play together. Takes effect at host or join.
@export var use_native_encoding: bool = true
## Where spawned entities go. Defaults to the current scene.
var world_root: Node = null
## Which address the server listens on. "*" is all of them.
var bind_address: String = "*"
# REFACTOR: the three packet limits below and bind_address are plain vars, not exports like the settings above, so a designer can't
# set them without code (designer friendly). See CHANGELOG.md.
## Server: most packets one client may send a second, so a broken or hostile client can't bury the server. Over it, [member max_bytes_per_second]
## or [member max_packet_bytes], packets are dropped and counted in stats (0: no limit). A pawn costs a client about 60 packets and 6 KB a second.
var max_packets_per_second: int = 2000
## Server: the most bytes one client may send a second. See [member max_packets_per_second].
var max_bytes_per_second: int = 256 * 1024
## Server: the largest packet a client may send. See [member max_packets_per_second].
var max_packet_bytes: int = 64 * 1024
## Something that can hold packets back on their way out and in, or null, which is normal. NetDebugModule fills it with its fake
## network. It has hold_outgoing(peer, bytes, reliable), hold_incoming(peer, bytes), release_due(now_usec) and clear().
var packet_filter: Object = null
## Bytes, packets and more, for diagnostics. A server counts snapshots_sent and snapshot_bytes (one per client per snapshot); a client
## snapshot_bytes_received, snapshot_parts_received and deltas_without_baseline; both the largest packet each way.
var stats := {"bytes_sent": 0, "bytes_received": 0, "packets_sent": 0, "packets_received": 0, "snapshots_received": 0,
		"corrections": 0, "correction_total": 0.0, "correction_worst": 0.0, "jump_total": 0.0, "jump_worst": 0.0, "resyncs": 0,
		"bad_packets": 0, "packets_over_limit": 0, "rejected_inputs": 0, "snapshots_encoded": 0, "schema_mismatches": 0, "interpolation_underruns": 0, "margin_total": 0, "margin_reports": 0,
		"margin_lowest": NO_MARGIN, "speed_lowest": 1.0, "speed_highest": 1.0, "snapshots_sent": 0, "snapshot_bytes": 0, "snapshot_bytes_received": 0,
		"snapshot_parts_received": 0, "deltas_without_baseline": 0, "largest_packet_sent": 0, "largest_packet_received": 0}
## The stats that only ever count up, which diagnostics turns into rates and averages per frame. Diagnostics' network summary also
## reads several by name (DiagnosticsManager._net_summary), so a rename goes there too.
const COUNTING_STATS: Array[String] = ["bytes_sent", "bytes_received", "snapshots_encoded", "snapshots_sent", "snapshot_bytes", "snapshots_received",
	"snapshot_bytes_received", "corrections", "resyncs", "interpolation_underruns"]
# Despawned entities waiting for their linger_until_tick (entity id -> true), despawned after it.
var _lingering := {}
## Client: which tick of the server's remote entities are being drawn at. -1 before the first snapshot.
var render_tick: float = -1.0
## Client: how loaded the server's ticks are, as a percentage of their budget (TickDriver.load_average), from the newest snapshot.
## -1 before the first. The samples' status line shows it, for profiling different hardware.
var server_load_percent: int = -1
## Client: the server's load ladder step (TickDriver.load_step), from the newest snapshot. -1 before the first.
var server_load_step: int = -1

## Seconds a new connection has to pass the handshake before the server drops it.
const HANDSHAKE_TIMEOUT := 5.0
## Pongs a client waits for before it sets its clock and starts ticking.
const SAMPLES_BEFORE_TICKING := 6
## Seconds between a client's pings while it's setting its clock.
const PING_INTERVAL_STARTING := 0.05
## Seconds between a client's pings once its clock is set.
const PING_INTERVAL := 0.25
## The project setting that names a build. See [method content_hash].
const BUILD_ID_SETTING := "project_base/network/build_id"
## The file types [method content_hash] reads when no build id is set.
const HASHED_FILE_TYPES: PackedStringArray = ["gd", "gdc", "tscn", "scn", "tres", "res"]
## Most packets the server keeps from one client between ticks, so one client can't crowd out others. A client sends one per pawn per tick,
## so 128 holds 4 pawns through a half-second freeze. A client doesn't cap what its server sends (see handle_packet).
const MAX_INBOX_PER_PEER := 128
## Most inputs one packet may carry. Fixed, because input_redundancy is a setting each machine has its own copy of.
const MAX_INPUTS_PER_PACKET := 16
## Snapshots are split into parts of at most this many bytes of entities, each its own packet, so none goes over ENet's packet size
## (1392 bytes) and the loss of one piece doesn't lose the whole snapshot.
const SNAPSHOT_PART_BYTES := 1100
## An entity's id with this bit set means its state list is a delta: [ticks back to the baseline, the change masks, the changed
## values]. Ids never get this high.
const DELTA_ID_BIT := 1 << 31
## How many state entries each change mask covers. 30 keeps a mask an int of at most 5 bytes, and 1 or 2 when only the first few
## entries changed.
const DELTA_MASK_BITS := 30
## The oldest baseline a delta may use, in ticks. Both sides keep 64 ticks, so this leaves room. A client that hasn't acknowledged
## anything this recent gets everything in full.
const DELTA_MAX_BASELINE_AGE := 48
## How many ticks of received state a client keeps per entity, for decoding deltas.
const BASELINE_RING := 64
# REFACTOR: a base autoload naming a file in netcode/debug/; docs/TEST_AND_DEBUG_CODE.md says a base class should never name a debug
# class (production kept apart from debug code). NetMonitors could attach itself instead, from an editor-only plugin or a
# DiagnosticsManager-style module. See CHANGELOG.md.
## The debugger graphs' script, loaded only if it's there (see _ready).
const NET_MONITORS_SCRIPT := "res://assets/scripts/netcode/debug/NetMonitors.gd"
## The most ticks one ACK packet may name. A client sends at most this many, and the server refuses a packet claiming more, so one
## packet can't make it walk through a long made-up list.
const MAX_ACK_ENTRIES := 8

# Small records with named fields, instead of lists read by position.
## What the server keeps about one connected client. Tests make theirs with _new_peer too.
class PeerRecord:
	var welcomed := false             # passed the handshake
	var connected_at := 0             # Time.get_ticks_usec() when it connected, for the handshake's time limit
	var margins: Array = []           # how early its recent inputs arrived, in ticks, for time dilation
	var newest_input := -1            # the newest tick it has sent input for
	var acknowledged_snapshot := -1   # the newest snapshot tick it says it read, for lag compensation
	var baselines: Dictionary = {}    # entity id -> the tick it last acknowledged that entity at (delta snapshots)
	var sent_parts: Dictionary = {}   # tick -> each part's entity ids, for the snapshots it may still acknowledge
	var limit_second := -1            # the second its packet counts below are for
	var limit_packets := 0
	var limit_bytes := 0


## A new client's record. Tests make theirs with this too.
func _new_peer(welcomed: bool) -> PeerRecord:
	var record := PeerRecord.new()
	record.welcomed = welcomed
	record.connected_at = Time.get_ticks_usec()
	return record

## One part of a snapshot on its way to a client: its encoded entities and their ids, so the client's ACK can say which arrived.
class SnapshotPart:
	var bytes := PackedByteArray()
	var ids := PackedInt32Array()

## Client: the parts of one snapshot read since the last ACK: how many parts it has, and a bit for each read.
class PartsRead:
	var part_count := 0
	var bits := PackedByteArray()

## Client: what the server sent for one entity over the last BASELINE_RING ticks: the tick in each slot and its state list.
class BaselineRing:
	var ticks := PackedInt64Array()
	var lists: Array = []


var _mode: Mode = Mode.OFFLINE
var _driver: Node = null
var _types: Dictionary = {}          # name -> PackedScene
var _type_order: Array[String] = []
var _entities: Dictionary = {}       # id -> NetworkEntity
var _entity_list: Array[NetworkEntity] = []
var _entity_list_dirty := true
var _next_entity_id := 1
var _peers: Dictionary = {}          # server: peer -> PeerRecord
var _inbox: Array = []               # [peer, bytes] waiting for the next tick
var _world_channels := {} # channel name's hash -> {"receive": Callable, "catch_up": Callable}
var _world_inbox: Array[PackedByteArray] = []
var _client_channels := {} # channel name's hash -> Callable(peer, bytes)
var _schema_warned := {} # entity types already warned about a schema mismatch, so it's said once each
var _inbox_counts: Dictionary = {}   # peer -> how many of those are theirs
var _codec: Object = null             # NetCodec, or null to use NetPackets
var _cached_hash := 0                # content_hash is costly and a client can ask for it, so it's kept
var _hash_is_cached := false
var _clock := NetClock.new()
var _clock_ready := false
var _next_ping_usec := 0
var _newest_snapshot_tick := -1
# Client: which parts of the newest snapshot have come (part -> true), so a duplicate is read once.
var _parts_got: Dictionary = {}
# Client: the parts read since the last ACK went, tick -> PartsRead, sent at the end of the tick; and the newest tick with any part
# read, which input packets carry for lag compensation. Parts are acknowledged one by one because a large snapshot almost never
# arrives whole (netcode spec 11.4.1).
var _acks_to_send: Dictionary = {}
var _newest_read_tick := -1
# Client: entity id -> BaselineRing (BASELINE_RING slots of ticks and state lists), what the server sent for it, to decode deltas
# against. Separate from the TickStateComponent's history, which a respawn clears.
var _baselines: Dictionary = {}
var _reconcile_values: Dictionary = {} # entity id -> {"state": Dictionary, "input": Dictionary} for the newest snapshot
var _reconcile_tick := -1
var _input_margin := NO_MARGIN         # client: the worst margin the server last reported
var _missed_inputs := 0                # client: how many of its inputs the server has lacked
var _last_feedback_usec := 0
var _last_snapshot_usec := 0
var _last_snapshot_tick := -1
var _snapshot_jitter_usec := 0.0
# Each connection's last known numbers, peer -> {"connected_usec", "heard_usec", "rtt_ms", "loss_percent", "reason"}, kept so they
# can still be reported once the connection has gone. On a client the one link is peer 1.
var _links: Dictionary = {}
var _next_link_check_usec := 0
# Why this game is about to call leave(), when it knows; leave() reports it and clears it.
var _ending_reason := ""
## How often each connection's round trip and packet loss are read from ENet, in microseconds.
const LINK_CHECK_INTERVAL_USEC := 500000


func _ready() -> void:
	process_priority = -200
	process_physics_priority = -200
	_driver = get_node_or_null("/root/TickDriver")
	if _driver == null:
		push_warning("[NetworkSession] no TickDriver autoload; multiplayer won't run")
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
	# The netcode's graphs in the editor's Debugger > Monitors, only while that debugger is attached. Loaded by file, not class name, so a
	# game exported without netcode/debug/ still loads this script. Deferred, so it runs after this frame's setup.
	if EngineDebugger.is_active() and ResourceLoader.exists(NET_MONITORS_SCRIPT):
		(load(NET_MONITORS_SCRIPT) as GDScript).call_deferred(&"on", self)


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
			set_tick_factor(1.0)
	if _mode == Mode.SERVER:
		_drop_silent_peers()
	_check_links(now)


# --- Connecting --------------------------------------------------------------------------------

## Adds a type of entity that can be spawned. Every machine must add the same ones.
func register_type(type_name: String, scene: PackedScene) -> void:
	if not _types.has(type_name):
		_type_order.append(type_name)
	_types[type_name] = scene
	_hash_is_cached = false


## The scene registered for this type name, or null. SpawnManager reads a type's team from it.
func get_type_scene(type_name: String) -> PackedScene:
	return _types.get(type_name)


## Starts a server. Returns OK or an error.
func host(port: int, max_clients: int = 32) -> Error:
	if _driver == null:
		return ERR_UNAVAILABLE # no tick driver, so nothing could run
	leave()
	content_hash() # it reads files, so now rather than as a hitch when the first client arrives
	_codec = _make_codec(NetPackets.PROTOCOL_VERSION)
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
	content_hash() # it reads files, so now rather than during the handshake
	_codec = _make_codec(NetPackets.PROTOCOL_VERSION)
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, port)
	if error != OK:
		return error
	multiplayer.multiplayer_peer = peer
	_mode = Mode.CLIENT
	_links[1] = _new_link() # the server's connection, from the moment of trying
	_driver.active = false # nothing ticks until the clock is set
	return OK


## Ends the session and removes everything it spawned. Safe to call at any time.
func leave() -> void:
	var was_online := _mode != Mode.OFFLINE
	# Say why it ended, while the connection's numbers are still here. A client reports its link to the
	# server; a server reports that it stopped, as peer 0. With no reason given, this game chose to leave.
	if was_online:
		var reason := _ending_reason if _ending_reason != "" else "this game left the session"
		if _mode == Mode.CLIENT:
			connection_ended.emit(1, reason, _link_details(1))
		else:
			connection_ended.emit(0, reason, {})
	_ending_reason = ""
	_links.clear()
	for entity_id: int in _entities.keys():
		_remove_entity(entity_id)
	_entities.clear()
	_entity_list_dirty = true
	_peers.clear()
	_inbox.clear()
	_inbox_counts.clear()
	_world_inbox.clear() # world messages from the last session mustn't reach the next one
	_reconcile_values.clear()
	_schema_warned.clear() # a new session warns afresh
	_reconcile_tick = -1
	_clock.reset()
	_clock_ready = false
	_newest_snapshot_tick = -1
	server_load_percent = -1
	server_load_step = -1
	_parts_got.clear()
	_acks_to_send.clear()
	_newest_read_tick = -1
	_baselines.clear()
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


## Whether this machine is offline, a server or a client.
func get_mode() -> Mode:
	return _mode


## True on a server (a host).
func is_server() -> bool:
	return _mode == Mode.SERVER


## The settings a start menu may offer before a match (MatchOptionsPanel.add_from_autoloads): the snapshots. The host's decide for
## everyone.
func get_match_options() -> PackedStringArray:
	return PackedStringArray(["snapshot_rate", "delta_snapshots_enabled"])


## Client: the tick of the newest snapshot that has arrived, -1 before any. How fast it climbs is how fast the server is really
## ticking, which the samples' status line shows.
func get_newest_snapshot_tick() -> int:
	return _newest_snapshot_tick


## True on a client, from join until it leaves.
func is_client() -> bool:
	return _mode == Mode.CLIENT


## This machine's peer id. Offline, and on the server, it's 1.
func get_local_peer() -> int:
	return 1 if _mode != Mode.CLIENT else multiplayer.get_unique_id()


## True while a real connection is up (not offline, and connected).
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


## How many ticks behind its own tick a client can believably be drawing others (lag compensation): no newer than its last acknowledged
## snapshot, no further behind that than the interpolation limit, and none past the rewind cap. Offline, the host's own pawn and AI aren't limited.
func limit_view_ticks_behind(peer: int, claimed: float, tick: int) -> float:
	if not _peers.has(peer):
		return claimed
	var acknowledged: int = _peers[peer].acknowledged_snapshot
	var age: int = tick - acknowledged
	if acknowledged < 0 or age > rewind_cap_seconds * _driver.get_tick_rate():
		return 0.0
	var interpolation_limit: float = max_interpolation_seconds * _driver.get_tick_rate()
	return minf(claimed, age + interpolation_limit + 1.0) # a client that acknowledges late on purpose gets through: it looks like high ping


## A number that's the same on two machines only if they run the same content; the handshake refuses a client whose differs. It covers the
## packet format, tag sets, input actions, engine build, physics settings, entity schemas, and the game's files (or [constant BUILD_ID_SETTING] if set).
func content_hash() -> int:
	if _hash_is_cached:
		return _cached_hash
	# REFACTOR: the netcode names other systems' tables here (TagRegistry, InputActions). A list that systems add their own part to
	# would let a game's own table join the check without editing the session (extensible). See CHANGELOG.md.
	var parts := PackedStringArray()
	parts.append(str(NetPackets.PROTOCOL_VERSION))
	parts.append(str(TagRegistry.content_hash())) # every category's tags, navigation's included
	# The named actions in bit order, so peers agree on what each input bit means even when a build id replaces the file part below.
	parts.append(",".join(InputActions.get_actions()))
	parts.append(String(Engine.get_version_info()["hash"]))
	# The tick rate isn't part of this. The server chooses it for the match and hands it over in WELCOME, but the hash is checked
	# before that, so a client started at the default rate must still match a 30-tick server.
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


## The name and contents of every script, scene and resource in this folder and below. Folders starting with
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
			if _peers[peer].welcomed:
				_send(peer, bytes, true)
	return entity.get_parent() if entity else null


## Server or offline: removes an entity everywhere. One whose [member NetworkEntity.linger_until_tick] is still ahead (a pawn with
## projectiles in flight) lingers, switched off, and goes the tick after.
func despawn(entity_id: int) -> void:
	if _mode == Mode.CLIENT or not _entities.has(entity_id):
		return
	var leaving: NetworkEntity = _entities[entity_id]
	if _driver and leaving.linger_until_tick >= _driver.tick:
		if not _lingering.has(entity_id):
			_lingering[entity_id] = true
			leaving.lingering_started.emit(leaving)
		return
	_lingering.erase(entity_id)
	var replicated: bool = _entities[entity_id].is_replicated
	_remove_entity(entity_id)
	if replicated and _mode == Mode.SERVER:
		var buffer := NetPackets.new_buffer()
		buffer.put_u8(NetPackets.Type.DESPAWN)
		buffer.put_u32(entity_id)
		for peer: int in _peers:
			if _peers[peer].welcomed:
				_send(peer, buffer.data_array, true)


# Despawns the lingering entities whose wait is over; one already gone is forgotten.
func _despawn_lingerers(tick: int) -> void:
	for entity_id: int in _lingering.keys():
		var entity: NetworkEntity = _entities.get(entity_id)
		if entity == null:
			_lingering.erase(entity_id)
		elif tick > entity.linger_until_tick:
			despawn(entity_id)


## Server or offline: gives an entity to another player, or to nobody with 0. Every client hears about it. From
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
			if _peers[peer].welcomed:
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


## The entity with this id, or null.
func get_entity(entity_id: int) -> NetworkEntity:
	return _entities.get(entity_id, null)


## Every live entity, in id order. The same list each time, rebuilt only when entities come and go, because several per-tick paths
## use it. Read it, don't change it.
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


## A switch changed: every entity works out its role again. NetDebugModule calls it after a feature switch, and a client after the
## server's features arrive.
func refresh_entities() -> void:
	for entity: NetworkEntity in get_entities():
		entity.set_role(_role_for(entity, entity.is_local))
		entity.refresh_input_saving() # a server's role doesn't change with default_predicted, but this does
		if entity.state:
			entity.state.follows_during_rollback = follow_during_rollback


func _forget_entity(entity_id: int) -> void:
	_entities.erase(entity_id)
	_baselines.erase(entity_id)
	for info: PeerRecord in _peers.values(): # server: and each client's baseline for it
		info.baselines.erase(entity_id)
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
	stats["largest_packet_sent"] = maxi(stats["largest_packet_sent"], bytes.size())
	if packet_filter == null or not packet_filter.hold_outgoing(peer, bytes, reliable):
		send_now(peer, bytes, reliable)


## Sends bytes straight away, past [member packet_filter]. NetDebugModule hands it to its fake network to send what it held back.
func send_now(peer: int, bytes: PackedByteArray, reliable: bool) -> void:
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
	# The biggest packet so far, and when this peer was last heard from (before any limit drops it: a peer over the limit is still
	# talking).
	stats["largest_packet_received"] = maxi(stats["largest_packet_received"], bytes.size())
	if _links.has(peer):
		_links[peer]["heard_usec"] = Time.get_ticks_usec()
	if bytes.is_empty():
		stats["bad_packets"] += 1
		return
	# Before anything else, so what's over the limit costs next to nothing.
	if _mode == Mode.SERVER and not _within_limits(peer, bytes):
		stats["packets_over_limit"] += 1
		return
	if packet_filter == null or not packet_filter.hold_incoming(peer, bytes):
		handle_packet(peer, bytes, true)


## Server: may this client send this packet now? Until it has passed the handshake, it may only send the packet that does that.
## Every packet counts against the per-second limits, pings included.
func _within_limits(peer: int, bytes: PackedByteArray) -> bool:
	if not _peers.has(peer):
		return false
	var info: PeerRecord = _peers[peer]
	if not info.welcomed and int(bytes[0]) != NetPackets.Type.HELLO:
		return false
	if max_packet_bytes > 0 and bytes.size() > max_packet_bytes:
		return false
	@warning_ignore("integer_division") # whole numbers on purpose
	var second := Time.get_ticks_msec() / 1000
	if int(info.limit_second) != second:
		info.limit_second = second
		info.limit_packets = 0
		info.limit_bytes = 0
	info.limit_packets += 1
	info.limit_bytes += bytes.size()
	if max_packets_per_second > 0 and int(info.limit_packets) > max_packets_per_second:
		return false
	return max_bytes_per_second <= 0 or int(info.limit_bytes) <= max_bytes_per_second


## Acts on one arrived packet, after [member packet_filter]. NetDebugModule hands it to its fake network to deliver what it held back.
func handle_packet(peer: int, bytes: PackedByteArray, _reliable: bool) -> void:
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
		NetPackets.Type.ACK:
			_on_ack(peer, bytes)
		NetPackets.Type.INPUT, NetPackets.Type.SNAPSHOT:
			var from_peer: int = _inbox_counts.get(peer, 0)
			if not _driver.active:
				pass # dropped: a client whose clock isn't set yet has no tick to put them on
			# The cap is the server's guard against a client flooding it. A client doesn't cap what its server sends: a large snapshot
			# is many parts, and two arriving in one frame would go over the cap and lose the newest.
			elif _mode == Mode.SERVER and from_peer >= MAX_INBOX_PER_PEER:
				stats["bad_packets"] += 1
			else:
				_inbox_counts[peer] = from_peer + 1
				_inbox.append([peer, bytes])
		_:
			stats["bad_packets"] += 1


# --- Handshake ---------------------------------------------------------------------------------

func _on_peer_connected(peer: int) -> void:
	if _mode == Mode.SERVER:
		_peers[peer] = _new_peer(false) # PeerRecord holds everything the server keeps about it
		_links[peer] = _new_link()


func _on_peer_disconnected(peer: int) -> void:
	# Reported first, including a peer _drop_silent_peers already removed from _peers. ENet can't tell a
	# client closing the connection from one that stopped answering; seconds_since_heard in the details can.
	if _mode == Mode.SERVER and _links.has(peer):
		var given: String = _links[peer]["reason"]
		connection_ended.emit(peer, given if given != "" else "the client closed the connection or stopped answering", _link_details(peer))
		_links.erase(peer)
	if _mode != Mode.SERVER or not _peers.has(peer):
		return
	var welcomed: bool = _peers[peer].welcomed
	_peers.erase(peer)
	# After the erase, so nothing is sent to the peer that's gone, and before the loop, so anything given a new
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
	_ending_reason = "could not reach the server"
	leave()
	refused.emit("could not reach the server")


func _on_server_disconnected() -> void:
	# ENet can't tell the server closing the connection from it no longer answering. ENet gives up on a
	# connection whose reliable packets go unanswered for several seconds, so a long seconds_since_heard in the details means that.
	_ending_reason = "the server closed the connection or stopped answering"
	leave()


func _on_hello(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.SERVER or not _peers.has(peer) or _peers[peer].welcomed:
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
	_peers[peer].welcomed = true
	var welcome := NetPackets.new_buffer()
	welcome.put_u8(NetPackets.Type.WELCOME)
	welcome.put_u16(_driver.get_tick_rate())
	_send(peer, welcome.data_array, true)
	for entity: NetworkEntity in get_entities():
		if entity.is_replicated:
			_send(peer, _spawn_packet(entity), true)
	_send_world_catch_up(peer)
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
	_ending_reason = "refused: " + reason
	leave()
	refused.emit(reason)


## A client that connected but never finished the handshake, or was refused and stayed.
func _drop_silent_peers() -> void:
	var now := Time.get_ticks_usec()
	for peer: int in _peers.keys():
		var info: PeerRecord = _peers[peer]
		if not info.welcomed and now - int(info.connected_at) > int(HANDSHAKE_TIMEOUT * 1000000.0):
			_peers.erase(peer)
			if _links.has(peer): # reported when ENet says it's gone
				_links[peer]["reason"] = "dropped: no handshake within %.0f s" % HANDSHAKE_TIMEOUT
			if multiplayer.multiplayer_peer:
				multiplayer.multiplayer_peer.disconnect_peer(peer)


# REFACTOR: a Dictionary read by string keys, where the server's other per-client record is a class (PeerRecord). A small LinkRecord
# class would catch a mistyped key when the script loads (reusable). See CHANGELOG.md.
## A new connection's numbers.
func _new_link() -> Dictionary:
	var now := Time.get_ticks_usec()
	return {"connected_usec": now, "heard_usec": now, "rtt_ms": -1, "loss_percent": -1.0, "reason": ""}


## Every LINK_CHECK_INTERVAL_USEC, each connection's round trip and packet loss as ENet measures them, kept because ENet can't be asked
## once a connection has gone. Skipped when the peer isn't an ENetMultiplayerPeer (a test's own kind).
func _check_links(now: int) -> void:
	if now < _next_link_check_usec or _links.is_empty():
		return
	_next_link_check_usec = now + LINK_CHECK_INTERVAL_USEC
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var connected := multiplayer.get_peers() # asked first: ENet complains about a peer it no longer has
	for peer: int in _links:
		if not connected.has(peer):
			continue
		var connection := enet.get_peer(peer)
		if connection == null:
			continue
		_links[peer]["rtt_ms"] = int(connection.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
		_links[peer]["loss_percent"] = 100.0 * connection.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / ENetPacketPeer.PACKET_LOSS_SCALE


## Each connection's last known numbers, peer -> {"seconds_connected", "seconds_since_heard", "rtt_ms",
## "loss_percent"}. On a client the one connection is peer 1, the server. Diagnostics shows these in its summaries.
func get_link_stats() -> Dictionary:
	var out := {}
	for peer: int in _links:
		out[peer] = _link_details(peer)
	return out


func _link_details(peer: int) -> Dictionary:
	var link: Dictionary = _links.get(peer, {})
	if link.is_empty():
		return {}
	var now := Time.get_ticks_usec()
	return {"seconds_connected": (now - int(link["connected_usec"])) / 1000000.0, "seconds_since_heard": (now - int(link["heard_usec"])) / 1000000.0,
		"rtt_ms": link["rtt_ms"], "loss_percent": link["loss_percent"]}


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


## Client: jumps the tick back to its target if it has drifted too far. Checked every frame, so a client that froze is back on time at
## once. The clock goes by the fastest recent ping, so a lag spike doesn't look like falling behind.
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
	# With dilation on, from the fastest recent ping, so a jump during a spike doesn't land on an inflated lead
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
# For changes to the world that aren't entities (terrain edits). The server sends reliably and in order, and each client gets them at the
# start of a tick. A channel's name is the same on every machine; one nobody registered is ignored.

## Sets up a channel. receive(bytes) runs on clients. catch_up() runs on the server when a client joins, and returns the bytes
## to send it, or empty for nothing.
func register_world_channel(channel: String, receive: Callable, catch_up: Callable = Callable()) -> void:
	_world_channels[hash(channel)] = {"receive": receive, "catch_up": catch_up}


## Removes a channel set up with [method register_world_channel].
func unregister_world_channel(channel: String) -> void:
	_world_channels.erase(hash(channel))


## Server: sends bytes to every client on a channel. Does nothing anywhere else.
func send_world_message(channel: String, bytes: PackedByteArray) -> void:
	if _mode != Mode.SERVER:
		return
	var packet := _world_packet(hash(channel), bytes)
	for peer: int in _peers:
		if _peers[peer].welcomed:
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
# The other direction: a client asks the server for something, so the session needn't know what. Reliable and in order, handled as they
# arrive. A client can send anything, so whatever receives these has to check it.

## Sets up a channel. receive(peer, bytes) runs on the server.
func register_client_channel(channel: String, receive: Callable) -> void:
	_client_channels[hash(channel)] = receive


## Removes a channel set up with [method register_client_channel].
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
	if _mode != Mode.SERVER or not _peers.has(peer) or not _peers[peer].welcomed or bytes.size() < 5:
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
	_deliver_world_messages() # first, so a snapshot after it is read in the world it describes
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
	if not _lingering.is_empty():
		_despawn_lingerers(tick)
	var profiling: bool = _driver.profile_enabled
	var mark := Time.get_ticks_usec() if profiling else 0
	if _mode == Mode.CLIENT:
		_send_inputs(tick)
		# Which snapshot parts it read, in an ACK of their own, whether or not it controls anything: a spectating client sends no
		# inputs, but still acknowledges what it read.
		_send_part_acks()
		if profiling:
			_profile_part(&"send_inputs", mark)
	elif _mode == Mode.SERVER and tick % _snapshot_interval() == 0:
		_send_snapshots(tick)
		if profiling:
			_profile_part(&"send_snapshots", mark)


## Adds the time since mark to one network part of a tick, in the driver's timing record. Returns now, the next part's mark.
func _profile_part(part: StringName, mark: int) -> int:
	var now := Time.get_ticks_usec()
	_driver.profile[part] = int(_driver.profile.get(part, 0)) + now - mark
	return now


func _snapshot_interval() -> int:
	return maxi(1, roundi(float(_driver.get_tick_rate()) / maxi(1, snapshot_rate)))


## Ticks between snapshots: a server sends one when the tick is a multiple of this. 1 without a tick driver.
func get_snapshot_interval() -> int:
	return _snapshot_interval() if _driver else 1


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
		# The newest snapshot this client has read any of, for lag compensation (how far back it can be seeing). Delta baselines come
		# from ACK packets. -1 if none yet.
		buffer.put_32(_newest_read_tick)
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


## Client: says which snapshot parts it has read since the last time, one ACK packet a tick at most: type, count u8 (up to 8, newest first),
## then per tick its tick u32, part count u8 and a bit per part (1: read, every entity in it). Unreliable: a lost ACK only keeps older baselines in use.
func _send_part_acks() -> void:
	if _acks_to_send.is_empty():
		return
	var ticks: Array = _acks_to_send.keys()
	ticks.sort()
	ticks.reverse()
	ticks = ticks.slice(0, MAX_ACK_ENTRIES)
	var buffer := NetPackets.new_buffer()
	buffer.put_u8(NetPackets.Type.ACK)
	buffer.put_u8(ticks.size())
	for tick: int in ticks:
		var entry: PartsRead = _acks_to_send[tick]
		buffer.put_u32(tick)
		buffer.put_u8(entry.part_count)
		buffer.put_data(entry.bits)
	_acks_to_send.clear()
	_send(1, buffer.data_array, false)


## Client: notes that it read a part of a snapshot, every entity in it, for the next ACK.
func _note_part_read(tick: int, part: int, part_count: int) -> void:
	if not _acks_to_send.has(tick):
		var entry := PartsRead.new()
		entry.part_count = part_count
		entry.bits.resize(ceili(part_count / 8.0))
		entry.bits.fill(0)
		_acks_to_send[tick] = entry
	var read: PartsRead = _acks_to_send[tick]
	@warning_ignore("integer_division") # whole numbers on purpose: which byte
	read.bits[part / 8] |= 1 << (part % 8)
	_newest_read_tick = maxi(_newest_read_tick, tick)


## Server: a client says which parts of which snapshots it read. Each entity in a read part gets that tick as its baseline for this client
## if newer. Unknown parts and future ticks are ignored. It also counts for lag compensation (only moves forward).
func _on_ack(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.SERVER or not _peers.has(peer) or not _peers[peer].welcomed or bytes.size() < 2:
		stats["bad_packets"] += 1
		return
	var info: PeerRecord = _peers[peer]
	var sent_parts: Dictionary = info.sent_parts
	var baselines: Dictionary = info.baselines
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	var entries := buffer.get_u8()
	# No more entries than a real client sends, and each tick once. Without these, one packet
	# could name the same snapshot over and over and have the server go through all its entities each time.
	if entries > MAX_ACK_ENTRIES:
		stats["bad_packets"] += 1
		return
	var ticks_done := PackedInt64Array()
	for e in entries:
		if not NetPackets.has_bytes(buffer, 5):
			stats["bad_packets"] += 1
			return
		var tick := buffer.get_u32()
		var part_count := buffer.get_u8()
		var mask_size := ceili(part_count / 8.0)
		if not NetPackets.has_bytes(buffer, mask_size):
			stats["bad_packets"] += 1
			return
		var mask: PackedByteArray = buffer.get_data(mask_size)[1]
		if tick > _driver.tick or ticks_done.has(tick):
			continue
		ticks_done.append(tick)
		info.acknowledged_snapshot = maxi(int(info.acknowledged_snapshot), tick)
		var parts: Variant = sent_parts.get(tick)
		if parts == null or (parts as Array).size() != part_count:
			continue
		for part in part_count:
			@warning_ignore("integer_division") # whole numbers on purpose: which byte
			if mask[part / 8] & (1 << (part % 8)) == 0:
				continue
			for entity_id in (parts[part] as PackedInt32Array):
				if int(baselines.get(entity_id, -1)) < tick:
					baselines[entity_id] = tick


## Server: stores a client's inputs for the ticks they belong to. Only the owner may send them, and they're cleaned first.
func _on_input(peer: int, bytes: PackedByteArray, tick: int) -> void:
	if not _peers.has(peer):
		return # its last packets, still waiting here when it left
	if _mode != Mode.SERVER or not _peers[peer].welcomed:
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
	# An empty packet is rejected too (count 0), and so is one claiming a newest tick further ahead than any history could hold, which
	# can't be real and would otherwise push this client's timing marker past every honest packet.
	if entity == null or entity.owner_peer != peer or entity.state == null or count == 0 or count > MAX_INPUTS_PER_PACKET \
			or newest >= tick + entity.state.history_size:
		stats["rejected_inputs"] += 1
		return
	# The whole packet is read first, so a broken one never counts towards the timing that drives time dilation and lag compensation.
	var lists: Array = []
	# Each input must have exactly this entity's input fields, checked before the timing is used.
	var field_count: int = entity.state.get_input_encodings().size()
	for i in count:
		var values: Variant = NetPackets.read_list(buffer)
		if values == null or (values as Array).size() != field_count:
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


## Server: the two timing reports for a client's next snapshot: its worst margin over the last half second and over the last 5; NO_MARGIN if
## unknown. A client silent for the short window (spectating, dead pawn) gets NO_MARGIN for both and its margins are dropped.
func _margins_to_report(info: PeerRecord, tick: int) -> PackedInt32Array:
	var margins: Array = info.margins
	if not margins.is_empty() and tick - int(info.newest_input) > _driver.ticks_at_rate(MARGIN_SHORT_WINDOW):
		margins.clear()
	if margins.is_empty():
		return PackedInt32Array([NO_MARGIN, NO_MARGIN])
	# The long check only counts once it covers the whole 5 seconds. A few calm packets prove nothing.
	return PackedInt32Array([margins.slice(-MARGIN_SHORT_WINDOW).min(), margins.min() if margins.size() >= MARGIN_LONG_WINDOW else NO_MARGIN])


## Server: how early this input packet arrived, for time dilation. Only packets with something new count (a duplicate isn't late input).
## What a client acknowledges only moves forward, and a client can't have seen the future.
func _note_input_timing(peer: int, newest: int, acknowledged: int, tick: int) -> void:
	var info: PeerRecord = _peers[peer]
	if newest > int(info.newest_input):
		info.newest_input = newest
		var margins: Array = info.margins
		margins.append(clampi(newest - tick, -30000, 30000))
		if margins.size() > MARGIN_LONG_WINDOW:
			margins.pop_front()
	if acknowledged <= tick:
		info.acknowledged_snapshot = maxi(int(info.acknowledged_snapshot), acknowledged)


# --- Snapshots ---------------------------------------------------------------------------------

## NetCodec if it's usable. Falls back to NetPackets if the library is missing, or was built for another
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


## Whether an entity goes in this tick's snapshot: it does if it recorded this tick, even with no state list (only save_state() data or
## sync properties). A paused entity records nothing, so it's left out.
func _is_in_snapshot(entity: NetworkEntity, tick: int) -> bool:
	return entity.is_replicated and entity.state != null and entity.state.has_state(tick)


# True if at least one client has passed the handshake.
func _has_welcomed_peer() -> bool:
	for peer: int in _peers:
		if _peers[peer].welcomed:
			return true
	return false


## Server: sends the world to every client, with a note for each on how its input is arriving, for time dilation.
func _send_snapshots(tick: int) -> void:
	# With no welcomed client nothing is gathered or encoded. Recording for rollback and lag compensation is TickStateComponent's and carries on;
	# a client that joins later gets a full snapshot at the next snapshot tick.
	if not _has_welcomed_peer():
		return
	# Each client gets each entity's changes since its baseline: the newest snapshot whose part holding that entity it acknowledged (_on_ack).
	# An encoding is made once per entity and baseline and shared. Entities are encoded one by one and cut into parts (SNAPSHOT_PART_BYTES), each
	# its own packet with the same tick; which entities went in which part is kept per client, so an ACK can say which arrived.
	var in_snapshot: Array[NetworkEntity] = []
	for entity: NetworkEntity in get_entities():
		if _is_in_snapshot(entity, tick):
			in_snapshot.append(entity)
	var server_features := 0
	for i in SERVER_FEATURES.size():
		if get(SERVER_FEATURES[i]):
			server_features |= 1 << i
	var missed_by_peer: Dictionary = {}
	for entity: NetworkEntity in get_entities():
		missed_by_peer[entity.owner_peer] = int(missed_by_peer.get(entity.owner_peer, 0)) + entity.missed_inputs
	# Key: (entity id, baseline tick); baseline -1 is "in full".
	var encoded: Dictionary = {}
	stats["snapshots_encoded"] += 1
	# The server's load, the same for every client and part, worked out once.
	var load_byte := clampi(roundi(_driver.load_average * 100.0), 0, 255)
	for peer: int in _peers:
		var info: PeerRecord = _peers[peer]
		if not info.welcomed:
			continue
		var baselines: Dictionary = info.baselines
		var sent_parts: Dictionary = info.sent_parts
		var chunks: Array[PackedByteArray] = []
		var ids := PackedInt32Array()
		for entity: NetworkEntity in in_snapshot:
			var baseline: int = baselines.get(entity.entity_id, -1) if delta_snapshots_enabled else -1
			if baseline >= tick or tick - baseline > DELTA_MAX_BASELINE_AGE:
				baseline = -1
			var key := Vector2i(entity.entity_id, baseline)
			if not encoded.has(key):
				var bytes := _delta_entity_bytes(entity, tick, baseline) if baseline >= 0 else PackedByteArray()
				if bytes.is_empty():
					var full := Vector2i(entity.entity_id, -1)
					if not encoded.has(full):
						encoded[full] = _encode_entities(_snapshot_entry(entity, tick, entity.entity_id, entity.state.get_state_values(tick), entity.state.get_state_encodings()))
					bytes = encoded[full]
				encoded[key] = bytes
			chunks.append(encoded[key])
			ids.append(entity.entity_id)
		var parts := _cut_into_parts(chunks, ids)
		# Which entities went in which part, for this client's ACKs; older snapshots than a baseline may use are forgotten.
		var part_ids: Array[PackedInt32Array] = []
		for part in parts:
			part_ids.append(part.ids)
		sent_parts[tick] = part_ids
		for old_tick: int in sent_parts.keys():
			if old_tick < tick - DELTA_MAX_BASELINE_AGE:
				sent_parts.erase(old_tick)
		# The header, the same for every part of this client's snapshot, made once; each part adds its number.
		var margins := _margins_to_report(info, tick)
		var header := NetPackets.new_buffer()
		header.put_u8(NetPackets.Type.SNAPSHOT)
		header.put_u32(tick)
		header.put_16(margins[0])
		header.put_16(margins[1])
		header.put_u32(missed_by_peer.get(peer, 0))
		header.put_u8(server_features)
		header.put_u8(load_byte) # the server's tick load (percent of the budget) and load step, for clients' diagnostics
		header.put_u8(_driver.load_step)
		var header_bytes := header.data_array
		stats["snapshots_sent"] += 1 # one per client, with the bytes it carries below
		for i in parts.size():
			var packet := NetPackets.new_buffer()
			packet.put_data(header_bytes)
			packet.put_u8(i) # which part this is, and how many there are
			packet.put_u8(parts.size())
			packet.put_u16(parts[i].ids.size())
			packet.put_data(parts[i].bytes)
			stats["snapshot_bytes"] += parts[i].bytes.size()
			_send(peer, packet.data_array, false)


## One entity's lists for the codec, as write_world takes them, with the given id and state list.
func _snapshot_entry(entity: NetworkEntity, tick: int, id: int, state_values: Array, state_encodings: Array) -> Array:
	return [id, state_values, state_encodings, entity.state.get_sync_values(), entity.state.get_sync_encodings(),
		# Other clients predicting this entity need to know what it wants. An empty list keeps it small otherwise.
		entity.state.get_input_values(tick) if (entity.is_predicted or default_predicted) else [], entity.state.get_input_encodings(),
		# What save_state returned, so clients can correct it. One byte if there's none.
		entity.state.get_custom_values(tick)]


func _encode_entities(entries: Array) -> PackedByteArray:
	return _codec.write_world(entries) if _codec != null else NetPackets.write_world(entries)


## An entity encoded as its changes since baseline, or empty if it must go in full (no state list, nothing saved for that tick, or a list
## too long). The state list becomes ticks back, masks, changed values; the id gets [constant DELTA_ID_BIT]; each mask covers [constant DELTA_MASK_BITS] entries.
func _delta_entity_bytes(entity: NetworkEntity, tick: int, baseline: int) -> PackedByteArray:
	var now := entity.state.get_state_values(tick)
	if now.is_empty() or not entity.state.has_state(baseline):
		return PackedByteArray()
	var then := entity.state.get_state_values(baseline)
	if then.size() != now.size():
		return PackedByteArray()
	var encodings := entity.state.get_state_encodings()
	# NetCodec.delta_state in C++ when the library is there, delta_state_lists otherwise. Same lists (tests/net_codec_selftest compares them).
	var lists: Array = _codec.delta_state(now, then, encodings, tick - baseline, DELTA_MASK_BITS) if _codec != null 			else delta_state_lists(now, then, encodings, tick - baseline)
	if lists.is_empty():
		return PackedByteArray()
	return _encode_entities(_snapshot_entry(entity, tick, entity.entity_id | DELTA_ID_BIT, lists[0], lists[1]))


## The change check for a delta: returns the values and encodings to send, laid out as ticks_back, masks, then each changed value. Empty if
## the lists differ in length or the result is too long. A value is unchanged if type and value match. Twin of NetCodec.delta_state (C++).
## Static, so it can be called without a session.
static func delta_state_lists(now: Array, then: Array, encodings: Array, ticks_back: int) -> Array:
	if now.size() != then.size():
		return []
	var masks_needed := ceili(now.size() / float(DELTA_MASK_BITS))
	var values: Array = [ticks_back]
	var codes: Array = [StateEncoding.RAW]
	var masks: Array = []
	masks.resize(masks_needed)
	masks.fill(0)
	values.append_array(masks)
	for i in masks_needed:
		codes.append(StateEncoding.RAW)
	# Arrays compare element by element in C++, so an unchanged entity costs one comparison.
	if now != then:
		for i in now.size():
			var a: Variant = now[i]
			var b: Variant = then[i]
			if typeof(a) == typeof(b) and a == b:
				continue
			@warning_ignore("integer_division") # whole numbers on purpose: which mask
			values[1 + i / DELTA_MASK_BITS] |= 1 << (i % DELTA_MASK_BITS)
			values.append(a)
			codes.append(encodings[i] if i < encodings.size() else StateEncoding.RAW)
	if values.size() > NetPackets.MAX_LIST_SIZE:
		return []
	return [values, codes]


## Groups encoded entities into parts of at most SNAPSHOT_PART_BYTES (a bigger one goes alone), with each chunk's entity id in ids. Always at
## least one part, so an empty snapshot still arrives; at most 255.
func _cut_into_parts(chunks: Array[PackedByteArray], ids: PackedInt32Array) -> Array[SnapshotPart]:
	var parts: Array[SnapshotPart] = []
	var part := SnapshotPart.new()
	for i in chunks.size():
		var chunk := chunks[i]
		if not part.ids.is_empty() and part.bytes.size() + chunk.size() > SNAPSHOT_PART_BYTES and parts.size() < 254:
			parts.append(part)
			part = SnapshotPart.new()
		part.bytes.append_array(chunk)
		part.ids.append(ids[i])
	parts.append(part)
	return parts


## Client: the features the server decides are whatever it says. default_predicted changes roles, so this matters in a real game too.
func _apply_server_features(mask: int) -> void:
	var changed := false
	for i in SERVER_FEATURES.size():
		var on: bool = mask & (1 << i) != 0
		if get(SERVER_FEATURES[i]) != on:
			set(SERVER_FEATURES[i], on)
			changed = true
	if changed:
		refresh_entities()


## Client: remote entities store what the snapshot says. Predicted ones keep it aside for _reconcile, newest only.
func _on_snapshot(peer: int, bytes: PackedByteArray) -> void:
	if _mode != Mode.CLIENT or peer != 1:
		stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	buffer.get_u8()
	if not NetPackets.has_bytes(buffer, 19): # the header below: tick, margins, missed, features, load, step, part, part count, count
		stats["bad_packets"] += 1
		return
	var tick := buffer.get_u32()
	var margin := buffer.get_16()
	var margin_long := buffer.get_16()
	var missed := buffer.get_u32()
	var server_features := buffer.get_u8()
	var load_percent := buffer.get_u8()
	var load_step := buffer.get_u8()
	var part := buffer.get_u8()
	var part_count := buffer.get_u8()
	var count := buffer.get_u16()
	# A snapshot comes in parts with the same tick, so only an older tick is out of date.
	if tick < _newest_snapshot_tick or part >= part_count:
		return # arrived out of order; a newer one already replaced it
	# The header above stays in GDScript, and the entities are read in one call.
	var parsed: Variant = _codec.read_world(bytes, buffer.get_position(), count) if _codec != null else NetPackets.read_world(buffer, count)
	if parsed == null:
		stats["bad_packets"] += 1
		return
	if tick > _newest_snapshot_tick:
		# The first part of a new snapshot: what the header says applies once per snapshot.
		_note_snapshot_timing(tick)
		_newest_snapshot_tick = tick
		_missed_inputs = missed
		stats["snapshots_received"] += 1
		_update_dilation(margin, margin_long)
		_apply_server_features(server_features)
		server_load_percent = load_percent
		server_load_step = load_step
		_reconcile_values.clear()
		_parts_got.clear()
	if _parts_got.has(part):
		return # a duplicate
	_parts_got[part] = true
	stats["snapshot_parts_received"] += 1
	stats["snapshot_bytes_received"] += bytes.size() # snapshots only, for their average size
	_reconcile_tick = tick # per part, so a part that comes after this tick's reconcile is still checked
	var all_read := true # every entity in this part read, so it can be acknowledged
	for item: Array in parsed:
		var entity_id: int = item[0] & ~DELTA_ID_BIT
		var entity: NetworkEntity = get_entity(entity_id)
		if entity == null or entity.state == null:
			all_read = false # its spawn hasn't arrived yet; the next snapshot covers it, and this part isn't acknowledged
			continue
		# A delta is rebuilt into the full list from the baseline it names.
		if item[0] & DELTA_ID_BIT:
			var rebuilt: Variant = _rebuild_from_delta(entity, tick, item[1])
			if rebuilt == null:
				all_read = false
				stats["deltas_without_baseline"] += 1
				continue
			item[1] = rebuilt
		# Lists of the wrong size are refused and reported, rather than read as empty, which would silently stop the entity updating.
		if not _snapshot_lists_fit(entity, item):
			all_read = false
			continue
		var state_list: Array = item[1]
		_keep_baseline(entity_id, tick, state_list)
		entity.state.apply_sync_values(item[2])
		# The list as it is, without a dictionary in between (receive_authoritative_values). Kept for all, so a switch takes effect
		# at once. Only entities this client predicts need the dictionary, for reconciling.
		entity.state.receive_authoritative_values(tick, state_list) # an empty list is fine: nothing that tick
		if not entity.follows_snapshots():
			_reconcile_values[entity_id] = {"state": entity.state.state_values_to_dictionary(state_list), "input": entity.state.input_values_to_dictionary(item[3]), "custom": item[4]}
	# Every entity in it read: this part goes in the next ACK.
	if all_read:
		_note_part_read(tick, part, part_count)


## Client: the full state list from a delta ([ticks back, masks..., changed values]) and what this
## client kept for that entity at the baseline tick. Null if the baseline isn't here or the delta doesn't fit.
func _rebuild_from_delta(entity: NetworkEntity, tick: int, delta: Array) -> Variant:
	var size: int = entity.state.get_list_sizes()[0]
	var masks_needed := ceili(size / float(DELTA_MASK_BITS))
	if size == 0 or delta.size() < 1 + masks_needed or typeof(delta[0]) != TYPE_INT:
		return null
	var base: Variant = _baseline_at(entity.entity_id, tick - int(delta[0]))
	if base == null or (base as Array).size() != size:
		return null
	var rebuilt: Array = (base as Array).duplicate() # shallow: an array inside is shared, but nothing changes them
	var next := 1 + masks_needed
	for m in masks_needed:
		var mask: Variant = delta[1 + m]
		if typeof(mask) != TYPE_INT:
			return null
		var bit := 0
		while mask != 0 and bit < DELTA_MASK_BITS:
			if mask & 1:
				var i := m * DELTA_MASK_BITS + bit
				if i >= size or next >= delta.size():
					return null
				rebuilt[i] = delta[next]
				next += 1
			mask >>= 1
			bit += 1
	# An if, not a ternary: an Array and null aren't one type.
	if next != delta.size():
		return null
	return rebuilt


## Client: keeps what the server sent for an entity on a tick, to decode later deltas against.
func _keep_baseline(entity_id: int, tick: int, values: Array) -> void:
	var ring: BaselineRing = _baselines.get(entity_id)
	if ring == null:
		ring = BaselineRing.new()
		ring.ticks.resize(BASELINE_RING)
		ring.ticks.fill(-1)
		ring.lists.resize(BASELINE_RING)
		_baselines[entity_id] = ring
	var slot := tick % BASELINE_RING
	ring.ticks[slot] = tick
	ring.lists[slot] = values


func _baseline_at(entity_id: int, tick: int) -> Variant:
	var ring: BaselineRing = _baselines.get(entity_id)
	if ring == null or tick < 0 or ring.ticks[tick % BASELINE_RING] != tick:
		return null
	return ring.lists[tick % BASELINE_RING]


# True if a snapshot's lists for this entity have the sizes its TickStateComponent expects (state, sync, input, custom: item[1] to item[4]). An empty
# list is fine: the server had nothing that tick. Another size means the builds differ (the content hash should have caught it): counted in
# stats.schema_mismatches, warned once per entity type, and the entity is skipped for this snapshot.
func _snapshot_lists_fit(entity: NetworkEntity, item: Array) -> bool:
	var sizes := entity.state.get_list_sizes()
	for i in sizes.size():
		var list: Variant = item[i + 1]
		var size := (list as Array).size() if list is Array else -1
		if size == 0 or size == sizes[i]:
			continue
		stats["schema_mismatches"] += 1
		if not _schema_warned.has(entity.type_name):
			_schema_warned[entity.type_name] = true
			var which: String = ["state", "sync", "input", "custom"][i]
			push_warning("[NetworkSession] entity type '%s': the server sent %d %s values, this machine declares %d. The two builds differ; its snapshots are ignored." % [entity.type_name, size, which, sizes[i]])
		return false
	return true


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

## Client: the server said how early our inputs arrived, at worst, over the last half second and the last 5. Too close over the short one:
## speed up, more the further out. Plenty to spare over the long one: slow down. Else normal speed; late costs inputs, early only a little.
func _update_dilation(margin: int, margin_long: int) -> void:
	_last_feedback_usec = Time.get_ticks_usec()
	if margin == NO_MARGIN:
		# Nothing known about our timing (we aren't sending inputs): normal speed, not the last correction held for ever.
		_input_margin = NO_MARGIN
		set_tick_factor(1.0)
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
	set_tick_factor(1.0 - clampf(error * dilation_gain, -dilation_max_speedup, dilation_max_slowdown))


## Client: sets how fast its ticks run compared to normal (time dilation), and notes the extremes in stats. NetDebugModule calls it
## too, to go back to normal speed.
func set_tick_factor(factor: float) -> void:
	_driver.tick_factor = factor
	stats["speed_lowest"] = minf(stats["speed_lowest"], factor)
	stats["speed_highest"] = maxf(stats["speed_highest"], factor)
