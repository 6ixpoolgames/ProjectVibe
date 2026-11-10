## Written by Claude (claude-opus-5-5), 2026-11-10: headless self-test for NetMonitors, the netcode's graphs in the editor's
## Debugger > Monitors: it isn't there unless asked for (no editor debugger in a test), every monitor is added and readable, the rates
## follow rollbacks, corrections and bytes, and the monitors go away with it.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/netcode/tests/net_monitors_selftest.tscn"
extends Node

var _failures := 0


func _ready() -> void:
	print("--- Net monitors self-test ---")
	await get_tree().process_frame
	_check(NetworkSession.get_node_or_null(^"NetMonitors") == null, "without the editor's debugger attached, the session doesn't add them")
	var monitors := NetMonitors.on(NetworkSession)
	_check(NetMonitors.on(NetworkSession) == monitors, "on() finds the one it added instead of adding another")
	var ids := monitors.get_monitor_ids()
	var all_there := ids.size() == 13
	for id in ids:
		all_there = all_there and Performance.has_custom_monitor(id) and String(id).begins_with("Net/")
	_check(all_there, "13 monitors under Net/ (%d)" % ids.size())
	_check(Performance.get_custom_monitor(&"Net/Ping (ms)") == 0.0 and Performance.get_custom_monitor(&"Net/Tick speed") == 1.0, "offline: no ping, normal tick speed")

	# A second's worth of activity: two replays of 3 and 5 ticks, 4 corrections totalling 2 m, 3 KB sent and 1 KB received.
	var stats: Dictionary = NetworkSession.stats
	var saved := stats.duplicate()
	var start := Time.get_ticks_usec()
	monitors.update_rates(start + 2_000_000) # starts the window
	TickDriver.after_rollback.emit(10, 13)
	TickDriver.after_rollback.emit(20, 25)
	stats["corrections"] += 4
	stats["correction_total"] += 2.0
	stats["bytes_sent"] += 3 * 1024
	stats["bytes_received"] += 1024
	monitors.update_rates(start + 3_000_000)
	_check(is_equal_approx(Performance.get_custom_monitor(&"Net/Rollbacks per second"), 2.0) and is_equal_approx(Performance.get_custom_monitor(&"Net/Ticks replayed per second"), 8.0), "rollbacks and replayed ticks per second (2 and 8)")
	_check(is_equal_approx(Performance.get_custom_monitor(&"Net/Corrections per second"), 4.0) and is_equal_approx(Performance.get_custom_monitor(&"Net/Average correction (m)"), 0.5), "corrections per second and their average size (4 and 0.5 m)")
	_check(is_equal_approx(Performance.get_custom_monitor(&"Net/Sent (KB per second)"), 3.0) and is_equal_approx(Performance.get_custom_monitor(&"Net/Received (KB per second)"), 1.0), "KB sent and received per second (3 and 1)")
	monitors.update_rates(start + 4_000_000)
	_check(Performance.get_custom_monitor(&"Net/Rollbacks per second") == 0.0 and Performance.get_custom_monitor(&"Net/Average correction (m)") == 0.0, "a quiet second after: back to 0")
	for key in saved:
		stats[key] = saved[key]

	monitors.queue_free()
	await get_tree().process_frame
	var gone := true
	for id in ids:
		gone = gone and not Performance.has_custom_monitor(id)
	_check(gone, "removed, the monitors go too")
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
