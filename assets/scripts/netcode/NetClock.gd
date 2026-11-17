# Written by Claude (claude-opus-5-5), 2026-11-04. History: netcode/CHANGELOG.md.
## A client's estimate of the server's clock (netcode spec section 4).
##
## The client feeds it pongs ([method add_sample]); it estimates the server's tick from the fastest recent ping and the round trip from
## the average. Times are microseconds, ticks are 60 a second.
## Design: netcode spec 4.
class_name NetClock
extends RefCounted

## How many recent pings count (about 4 s at the usual ping rate).
const MAX_SAMPLES := 16

var _samples: Array[Dictionary] = [] # {rtt: usec, server_tick_at_receive: float, received: usec}


## Forgets everything, for a new connection.
func reset() -> void:
	_samples.clear()


## Records a pong: when the ping was sent and the pong received (microseconds), the server tick it carried, and the length of a tick.
func add_sample(sent_usec: int, received_usec: int, server_tick: int, tick_usec: float) -> void:
	var rtt := maxi(received_usec - sent_usec, 0)
	_samples.append({
		"rtt": rtt,
		"server_tick_at_receive": server_tick + (rtt * 0.5) / tick_usec,
		"received": received_usec,
	})
	if _samples.size() > MAX_SAMPLES:
		_samples.pop_front()


## How many pongs are being remembered, up to [constant MAX_SAMPLES].
func get_sample_count() -> int:
	return _samples.size()


## The average round trip in microseconds. 0 before any sample.
func get_rtt_usec() -> float:
	if _samples.is_empty():
		return 0.0
	var total := 0
	for sample: Dictionary in _samples:
		total += sample["rtt"]
	return float(total) / _samples.size()


## How much the round trip varies, in microseconds (standard deviation).
func get_jitter_usec() -> float:
	if _samples.size() < 2:
		return 0.0
	var average := get_rtt_usec()
	var total := 0.0
	for sample: Dictionary in _samples:
		var difference: float = sample["rtt"] - average
		total += difference * difference
	return sqrt(total / _samples.size())


## Which tick the server is on right now, from the fastest recent ping. 0 before any sample.
func estimate_server_tick(now_usec: int, tick_usec: float) -> float:
	if _samples.is_empty():
		return 0.0
	var best: Dictionary = _samples[0]
	for sample: Dictionary in _samples:
		if sample["rtt"] < best["rtt"]:
			best = sample
	var since: int = now_usec - best["received"]
	return best["server_tick_at_receive"] + since / tick_usec


## The fastest recent round trip in microseconds, which a lag spike doesn't inflate. 0 before any sample.
func get_lowest_rtt_usec() -> float:
	if _samples.is_empty():
		return 0.0
	var lowest: int = _samples[0]["rtt"]
	for sample: Dictionary in _samples:
		lowest = mini(lowest, sample["rtt"])
	return float(lowest)


## How many ticks ahead of the server a client should run: half the round trip plus [code]margin_ticks[/code].
## [br][code]from_lowest[/code] uses the fastest ping instead of the average, since time dilation adds whatever more is needed.
func get_lead_ticks(tick_usec: float, margin_ticks: int, from_lowest: bool = false) -> int:
	var rtt := get_lowest_rtt_usec() if from_lowest else get_rtt_usec()
	return ceili(rtt * 0.5 / tick_usec) + margin_ticks
