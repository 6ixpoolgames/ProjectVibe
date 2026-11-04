## Written by Claude (claude-opus-5-5), 2026-11-04: pretends the network is bad, for testing (netcode spec build order).
## Sits on the sending side of NetworkSession. Packets wait here before really being sent, so a machine set to 50 ms adds
## 50 ms each way, 100 ms to the round trip when both ends use it. Off unless a value is set.
##
## Rules:
##   - Unreliable packets can be lost, and jitter can put them out of order, like a real network.
##   - Reliable packets are never lost and always stay in order, because that's what ENet promises. They still get delayed.
##   - Packets leave on the next check after their time, so the real delay is rounded up to a frame or so.
class_name NetFakeConditions
extends RefCounted

## Added to each packet, one way, in milliseconds.
var latency_ms: float = 0.0
## Extra random delay added to each packet, from 0 up to this, in milliseconds.
var jitter_ms: float = 0.0
## Chance from 0 to 1 that an unreliable packet disappears.
var loss: float = 0.0

var _waiting: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _last_reliable_release := 0
var packets_lost := 0


func is_active() -> bool:
	return latency_ms > 0.0 or jitter_ms > 0.0 or loss > 0.0


func set_seed(new_seed: int) -> void:
	_rng.seed = new_seed


## Holds a packet until it's due. send is called later with (peer, bytes, reliable).
func submit(peer: int, bytes: PackedByteArray, reliable: bool, now_usec: int) -> void:
	if not reliable and _rng.randf() < loss:
		packets_lost += 1
		return
	var delay_ms := latency_ms + _rng.randf() * jitter_ms
	var release: int = now_usec + roundi(delay_ms * 1000.0)
	if reliable:
		release = maxi(release, _last_reliable_release)
		_last_reliable_release = release
	_waiting.append({"release": release, "peer": peer, "bytes": bytes, "reliable": reliable})


## Sends everything that's due, in release order.
func release_due(now_usec: int, send: Callable) -> void:
	if _waiting.is_empty():
		return
	var still_waiting: Array[Dictionary] = []
	var due: Array[Dictionary] = []
	for packet: Dictionary in _waiting:
		if packet["release"] <= now_usec:
			due.append(packet)
		else:
			still_waiting.append(packet)
	_waiting = still_waiting
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["release"] < b["release"])
	for packet: Dictionary in due:
		send.call(packet["peer"], packet["bytes"], packet["reliable"])


func clear() -> void:
	_waiting.clear()
	_last_reliable_release = 0
