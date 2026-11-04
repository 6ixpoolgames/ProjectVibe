## Written by Claude (claude-opus-5-5), 2026-11-04: pretends the network is bad, for testing (netcode spec section 16).
## Packets wait here before really being sent or handled. NetworkSession has two of these: `fake` for what it sends and
## `fake_in` for what it receives, so one window can set its whole ping. Off unless a value is set. Every setting can
## change while running, and a fixed seed makes a run repeatable.
##
## What it can do (netcode spec section 16 lists the presets):
##   latency_ms         a fixed delay on every packet
##   jitter_ms          a random extra delay on each packet, from 0 up to this
##   jitter_variation   0 to 1: how much jitter itself wanders over time, so a connection goes from calm to rough and back
##   loss               chance that an unreliable packet disappears
##   burst_*            short periods where every unreliable packet is lost and reliable ones wait, as on a real bad link
##   spike_*            short periods of much higher latency
##   reorder_chance     chance a packet gets held back, so it arrives after later ones
##   duplicate_chance   chance an unreliable packet arrives twice
##   timeline           latency that changes over time, as [[seconds, milliseconds], ...], for repeatable ramps
##
## Rules:
##   - Reliable packets are never lost, duplicated or reordered, because that's what ENet promises. They still get delayed.
##   - Packets are released on the next check after their time, so a real delay is rounded up to a frame or so.
##   - start_burst and start_spike trigger one by hand, whatever the chance settings.
class_name NetFakeConditions
extends RefCounted

## Round-trip figures for a whole connection. apply_preset gives each direction its share.
const PRESETS := {
	"off": {},
	"good": {"latency": 30.0, "jitter": 2.0},
	"wifi": {"latency": 60.0, "jitter": 20.0, "variation": 0.5, "loss": 0.01, "spike_rate": 0.05, "spike_ms": 100.0, "spike_seconds": 0.5, "burst_rate": 0.03, "burst_seconds": 0.15},
	"mobile": {"latency": 120.0, "jitter": 40.0, "variation": 0.7, "loss": 0.03, "spike_rate": 0.1, "spike_ms": 250.0, "spike_seconds": 1.0, "burst_rate": 0.05, "burst_seconds": 0.4, "reorder": 0.02},
	"worst": {"latency": 250.0, "jitter": 80.0, "variation": 1.0, "loss": 0.08, "spike_rate": 0.25, "spike_ms": 500.0, "spike_seconds": 1.5, "burst_rate": 0.15, "burst_seconds": 1.0, "reorder": 0.05, "duplicate": 0.02},
}

var latency_ms: float = 0.0
var jitter_ms: float = 0.0
var jitter_variation: float = 0.0
var loss: float = 0.0
var burst_rate_per_second: float = 0.0
var burst_seconds: float = 0.5
var spike_rate_per_second: float = 0.0
var spike_ms: float = 200.0
var spike_seconds: float = 0.5
var reorder_chance: float = 0.0
var reorder_ms: float = 80.0
var duplicate_chance: float = 0.0
## Latency over time, as [[seconds, milliseconds], ...] in order. Overrides latency_ms while set.
var timeline: Array = []

var packets_lost := 0
var bursts_started := 0
var spikes_started := 0

var _waiting: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _last_reliable_release := 0
var _last_update_usec := -1
var _timeline_start_usec := -1
var _burst_until_usec := 0
var _spike_until_usec := 0
var _spike_extra_ms := 0.0
var _jitter_level := 1.0
var _next_wander_usec := 0


func is_active() -> bool:
	return latency_ms > 0.0 or jitter_ms > 0.0 or loss > 0.0 or burst_rate_per_second > 0.0 or spike_rate_per_second > 0.0 \
			or reorder_chance > 0.0 or duplicate_chance > 0.0 or not timeline.is_empty() or not _waiting.is_empty() \
			or _burst_until_usec > 0 or _spike_until_usec > 0


func set_seed(new_seed: int) -> void:
	_rng.seed = new_seed


## Sets everything to a named preset, taking this share of its round-trip figures. Each direction normally takes 0.5.
## A spike's size isn't shared: each direction spikes on its own, so it has to be the full size to add that much to the ping.
func apply_preset(preset_name: String, share: float = 0.5) -> void:
	var preset: Dictionary = PRESETS.get(preset_name, {})
	latency_ms = float(preset.get("latency", 0.0)) * share
	jitter_ms = float(preset.get("jitter", 0.0)) * share
	jitter_variation = preset.get("variation", 0.0)
	loss = float(preset.get("loss", 0.0)) * share
	spike_rate_per_second = float(preset.get("spike_rate", 0.0)) * share
	spike_ms = float(preset.get("spike_ms", 200.0))
	spike_seconds = preset.get("spike_seconds", 0.5)
	burst_rate_per_second = float(preset.get("burst_rate", 0.0)) * share
	burst_seconds = preset.get("burst_seconds", 0.5)
	reorder_chance = float(preset.get("reorder", 0.0)) * share
	duplicate_chance = float(preset.get("duplicate", 0.0)) * share
	timeline = []


## For this many seconds from now, every unreliable packet is lost and reliable ones wait.
func start_burst(now_usec: int, seconds: float) -> void:
	bursts_started += 1
	_burst_until_usec = maxi(_burst_until_usec, now_usec + roundi(seconds * 1000000.0))


## For this many seconds from now, every packet takes this much longer.
func start_spike(now_usec: int, seconds: float, extra_ms: float) -> void:
	spikes_started += 1
	_spike_extra_ms = extra_ms
	_spike_until_usec = maxi(_spike_until_usec, now_usec + roundi(seconds * 1000000.0))


func is_in_burst(now_usec: int) -> bool:
	return now_usec < _burst_until_usec


func is_in_spike(now_usec: int) -> bool:
	return now_usec < _spike_until_usec


## The jitter limit right now, after it has wandered.
func get_current_jitter_ms() -> float:
	return jitter_ms * _jitter_level


## Moves random events and the timeline along. Runs on its own from release_due.
func update(now_usec: int) -> void:
	var elapsed := 0.0 if _last_update_usec < 0 else (now_usec - _last_update_usec) / 1000000.0
	_last_update_usec = now_usec
	# Over, so is_active can go back to false and packets stop passing through here.
	if now_usec >= _burst_until_usec:
		_burst_until_usec = 0
	if now_usec >= _spike_until_usec:
		_spike_until_usec = 0
	if not timeline.is_empty():
		if _timeline_start_usec < 0:
			_timeline_start_usec = now_usec
		latency_ms = _timeline_latency((now_usec - _timeline_start_usec) / 1000000.0)
	if burst_rate_per_second > 0.0 and _rng.randf() < burst_rate_per_second * elapsed:
		start_burst(now_usec, burst_seconds)
	if spike_rate_per_second > 0.0 and _rng.randf() < spike_rate_per_second * elapsed:
		start_spike(now_usec, spike_seconds, spike_ms)
	if jitter_variation > 0.0 and now_usec >= _next_wander_usec:
		_next_wander_usec = now_usec + 100000
		var lowest := 1.0 - jitter_variation
		var highest := 1.0 + jitter_variation
		_jitter_level = clampf(_jitter_level + _rng.randf_range(-0.25, 0.25) * jitter_variation, lowest, highest)
	elif jitter_variation <= 0.0:
		_jitter_level = 1.0


## Holds a packet until it's due, or loses it. Sending happens in release_due.
func submit(peer: int, bytes: PackedByteArray, reliable: bool, now_usec: int) -> void:
	var in_burst := is_in_burst(now_usec)
	if not reliable and (in_burst or _rng.randf() < loss):
		packets_lost += 1
		return
	var delay_ms := latency_ms + _rng.randf() * get_current_jitter_ms()
	if is_in_spike(now_usec):
		delay_ms += _spike_extra_ms
	var release: int = now_usec + roundi(delay_ms * 1000.0)
	if reliable:
		if in_burst:
			release = maxi(release, _burst_until_usec)
		release = maxi(release, _last_reliable_release) # stays in order
		_last_reliable_release = release
	elif _rng.randf() < reorder_chance:
		release += roundi(reorder_ms * 1000.0)
	_waiting.append({"release": release, "peer": peer, "bytes": bytes, "reliable": reliable})
	if not reliable and _rng.randf() < duplicate_chance:
		_waiting.append({"release": release + 1000, "peer": peer, "bytes": bytes, "reliable": false})


## Hands over everything that's due, in release order. send is called with (peer, bytes, reliable).
func release_due(now_usec: int, send: Callable) -> void:
	update(now_usec)
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
	_burst_until_usec = 0
	_spike_until_usec = 0
	_timeline_start_usec = -1


func _timeline_latency(seconds: float) -> float:
	var previous: Array = timeline[0]
	if seconds <= float(previous[0]):
		return float(previous[1])
	for point: Array in timeline:
		if seconds <= float(point[0]):
			var span := float(point[0]) - float(previous[0])
			var weight := (seconds - float(previous[0])) / maxf(span, 0.001)
			return lerpf(float(previous[1]), float(point[1]), weight)
		previous = point
	return float(previous[1])
