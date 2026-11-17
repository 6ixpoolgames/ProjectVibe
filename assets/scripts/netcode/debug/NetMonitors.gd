# Written by Claude (claude-opus-5-5), 2026-11-10. History: netcode/CHANGELOG.md.
## The netcode's numbers as graphs in Godot's debugger (debug code).
##
## Run the game from the editor and open Debugger > Monitors: they are under "Net", live while host and clients run. Nothing is drawn
## in the game. An optional child of the session, added when the editor's debugger is attached; elsewhere: [code]NetMonitors.on(NetworkSession)[/code].
## It only reads (TickDriver.after_rollback, the session's getters and stats). Rates are per second, worked out once a second; a
## client-only number is 0 on the server and offline.
## [br]Monitors: Ping (ms), Lead (ticks), View behind (ticks), Tick speed (time dilation, 1 is normal), Rollbacks per second, Ticks
## replayed per second, Corrections per second, Average correction (m), Sent and Received (KB per second), Input margin (ticks, negative
## is late), Missed inputs, Entities.
class_name NetMonitors
extends Node

## Put before every monitor's name.
const PREFIX := "Net/"
## Seconds between working out the rates.
const RATE_SECONDS := 1.0

var _session: NetworkSessionSingleton = null
var _driver: Node = null
var _ids: Array[StringName] = []
var _rollbacks := 0
var _replayed_ticks := 0
var _rates := {"rollbacks": 0.0, "replayed": 0.0, "corrections": 0.0, "correction_size": 0.0, "sent_kb": 0.0, "received_kb": 0.0}
var _last := {"rollbacks": 0, "replayed": 0, "corrections": 0, "correction_total": 0.0, "bytes_sent": 0, "bytes_received": 0}
var _last_usec := 0


## The monitors on this session, adding them the first time.
static func on(session: NetworkSessionSingleton) -> NetMonitors:
	var existing := session.get_node_or_null(^"NetMonitors") as NetMonitors
	if existing:
		return existing
	var monitors := NetMonitors.new()
	monitors.name = "NetMonitors"
	session.add_child(monitors)
	return monitors


func _enter_tree() -> void:
	_session = get_parent() as NetworkSessionSingleton
	if _session == null:
		push_warning("NetMonitors: its parent isn't a NetworkSession, so it does nothing.")
		return
	_driver = get_node_or_null("/root/TickDriver")
	if _driver and not _driver.after_rollback.is_connected(_on_after_rollback):
		_driver.after_rollback.connect(_on_after_rollback)
	_last_usec = Time.get_ticks_usec()
	_add(&"Ping (ms)", func() -> float: return _session.get_rtt_ms() if _session.is_client() else 0.0)
	_add(&"Lead (ticks)", func() -> float: return _session.get_lead_ticks())
	_add(&"View behind (ticks)", func() -> float: return _session.get_view_ticks_behind())
	_add(&"Tick speed", func() -> float: return _session.get_tick_factor())
	_add(&"Rollbacks per second", func() -> float: return _rates["rollbacks"])
	_add(&"Ticks replayed per second", func() -> float: return _rates["replayed"])
	_add(&"Corrections per second", func() -> float: return _rates["corrections"])
	_add(&"Average correction (m)", func() -> float: return _rates["correction_size"])
	_add(&"Sent (KB per second)", func() -> float: return _rates["sent_kb"])
	_add(&"Received (KB per second)", func() -> float: return _rates["received_kb"])
	_add(&"Input margin (ticks)", func() -> float:
		var margin := _session.get_input_margin()
		return 0.0 if margin == NetworkSessionSingleton.NO_MARGIN else float(margin))
	_add(&"Missed inputs", func() -> float: return float(_session.get_missed_inputs()))
	_add(&"Entities", func() -> float: return float(_session.get_entities().size()))


func _exit_tree() -> void:
	for id in _ids:
		if Performance.has_custom_monitor(id):
			Performance.remove_custom_monitor(id)
	_ids.clear()
	if _driver and _driver.after_rollback.is_connected(_on_after_rollback):
		_driver.after_rollback.disconnect(_on_after_rollback)
	_session = null


## Works out the rates once a second. Godot reads the monitors on its own schedule, so they read stored numbers.
func _process(_delta: float) -> void:
	update_rates(Time.get_ticks_usec())


## The rates since the last time, if a second has passed. Called each frame; a test can call it with its own time.
func update_rates(now_usec: int) -> void:
	var seconds := (now_usec - _last_usec) / 1_000_000.0
	if seconds < RATE_SECONDS or _session == null:
		return
	var stats: Dictionary = _session.stats
	var corrections: int = stats["corrections"] - _last["corrections"]
	_rates["rollbacks"] = (_rollbacks - _last["rollbacks"]) / seconds
	_rates["replayed"] = (_replayed_ticks - _last["replayed"]) / seconds
	_rates["corrections"] = corrections / seconds
	_rates["correction_size"] = (stats["correction_total"] - _last["correction_total"]) / corrections if corrections > 0 else 0.0
	_rates["sent_kb"] = (stats["bytes_sent"] - _last["bytes_sent"]) / 1024.0 / seconds
	_rates["received_kb"] = (stats["bytes_received"] - _last["bytes_received"]) / 1024.0 / seconds
	_last = {"rollbacks": _rollbacks, "replayed": _replayed_ticks, "corrections": stats["corrections"], "correction_total": stats["correction_total"],
			"bytes_sent": stats["bytes_sent"], "bytes_received": stats["bytes_received"]}
	_last_usec = now_usec


## The monitor ids it added, such as &"Net/Ping (ms)".
func get_monitor_ids() -> Array[StringName]:
	return _ids.duplicate()


func _add(label: StringName, value: Callable) -> void:
	var id := StringName(PREFIX + label)
	if Performance.has_custom_monitor(id):
		Performance.remove_custom_monitor(id) # left by an earlier copy
	Performance.add_custom_monitor(id, value)
	_ids.append(id)


func _on_after_rollback(from_tick: int, to_tick: int) -> void:
	_rollbacks += 1
	_replayed_ticks += to_tick - from_tick
