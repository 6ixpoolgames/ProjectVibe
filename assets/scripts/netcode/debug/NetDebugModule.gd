## Written by Claude (claude-opus-5-5), 2026-11-07: everything for testing multiplayer at its worst that used to live in NetworkSession: the
## fake bad network and switching features while running. It's an optional child of the session, because a test scene can't swap an autoload
## for an extension. Without one, the session does none of this. Approach: docs/TEST_AND_DEBUG_CODE.md.
##
## How to use it:
##   var debug := NetDebugModule.on(NetworkSession)   # finds it, or adds it the first time
##   debug.fake.latency_ms = 100.0                    # what this machine sends. fake_in is what it receives
##   debug.set_feature("prediction_enabled", false)
##
## NetTestBench puts all of this on keys.
##
## What happens in odd cases (all checked in tests/net_selftest.gd):
##   - An unknown feature: it warns and changes nothing.
##   - A client switching something the server decides: it only asks, and the server has to have allow_debug_commands on.
##   - A server without this module gets such a request: it counts as a bad packet, like any unknown message.
class_name NetDebugModule
extends Node

## Every switch set_feature understands, in the order NetTestBench shows them.
const FEATURES: Array[String] = ["prediction_enabled", "reconciliation_enabled", "interpolation_enabled", "extrapolation_enabled", "correction_smoothing_enabled", "lag_compensation_enabled", "default_predicted", "follow_during_rollback", "time_dilation_enabled", "adaptive_interpolation_enabled"]
const CHANNEL := "net_debug_switch"

## Pretend the network is bad. One for what this machine sends, one for what it receives. See NetFakeConditions.
var fake := NetFakeConditions.new()
var fake_in := NetFakeConditions.new()
## Server: obey test switches sent by clients. Also needs a debug build.
var allow_debug_commands := false

var _session: NetworkSessionSingleton = null


## The module on this session, adding one if it has none.
static func on(session: NetworkSessionSingleton) -> NetDebugModule:
	var existing := session.get_node_or_null(^"NetDebugModule") as NetDebugModule
	if existing:
		return existing
	var module := NetDebugModule.new()
	module.name = "NetDebugModule"
	session.add_child(module)
	return module


func _enter_tree() -> void:
	_session = get_parent() as NetworkSessionSingleton
	if _session == null:
		push_warning("NetDebugModule: its parent isn't a NetworkSession, so it does nothing.")
		return
	_session.packet_filter = self
	_session.register_client_channel(CHANNEL, _on_switch_request)


func _exit_tree() -> void:
	if _session:
		_session.packet_filter = null
		_session.unregister_client_channel(CHANNEL)
	_session = null


func is_feature_on(feature: String) -> bool:
	return FEATURES.has(feature) and _session.get(feature)


## Turns a feature on or off, even while running. On a client, a feature the server decides only changes if the server agrees: the
## next snapshot says.
func set_feature(feature: String, on: bool) -> void:
	if not FEATURES.has(feature):
		push_warning("NetDebugModule: no feature called '%s'" % feature)
		return
	if _session.is_client() and NetworkSessionSingleton.SERVER_FEATURES.has(feature):
		_session.send_to_server(CHANNEL, switch_message(feature, on))
		return
	_session.set(feature, on)
	_session._refresh_entities()
	if not _session.time_dilation_enabled and _session._driver:
		_session._set_tick_factor(1.0)


## What a client sends to ask for a switch.
func switch_message(feature: String, on: bool) -> PackedByteArray:
	var buffer := NetPackets.new_buffer()
	NetPackets.write_value(buffer, feature, StateEncoding.RAW)
	NetPackets.write_value(buffer, on, StateEncoding.RAW)
	return buffer.data_array


## Server: a client's test switch. Refused unless this is a debug build and the game allows it, and only for SERVER_FEATURES.
func _on_switch_request(_peer: int, bytes: PackedByteArray) -> void:
	if not allow_debug_commands or not OS.is_debug_build():
		_session.stats["bad_packets"] += 1
		return
	var buffer := NetPackets.reader(bytes)
	var feature: Variant = NetPackets.read_value(buffer)
	var on: Variant = NetPackets.read_value(buffer)
	if feature is String and NetworkSessionSingleton.SERVER_FEATURES.has(feature) and on is bool:
		_session.set(feature, on)
		_session._refresh_entities()
	else:
		_session.stats["bad_packets"] += 1


# --- The session's packet filter: it calls these if it has one ---


## True if this has taken the packet, to send later.
func hold_outgoing(peer: int, bytes: PackedByteArray, reliable: bool) -> bool:
	if not fake.is_active():
		return false
	fake.submit(peer, bytes, reliable, Time.get_ticks_usec())
	return true


## True if this has taken the packet, to handle later.
func hold_incoming(peer: int, bytes: PackedByteArray) -> bool:
	if not fake_in.is_active():
		return false
	fake_in.submit(peer, bytes, _is_reliable_type(int(bytes[0])), Time.get_ticks_usec())
	return true


## Lets go of whatever has waited long enough.
func release_due(now_usec: int) -> void:
	fake.release_due(now_usec, _session._send_now)
	fake_in.release_due(now_usec, _session._handle_packet)


## The session has ended.
func clear() -> void:
	fake.clear()
	fake_in.clear()


func _is_reliable_type(type: int) -> bool:
	return type != NetPackets.Type.INPUT and type != NetPackets.Type.SNAPSHOT and type != NetPackets.Type.PING and type != NetPackets.Type.PONG
