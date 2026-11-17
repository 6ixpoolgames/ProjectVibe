## Written by Claude (claude-opus-5-5), 2026-11-16: measures the mass battle over a real network connection, the owner's request after
## a networked playtest overloaded the CPU, lagged and hitched on the client, and dropped the client. Not pass/fail: like
## mass_battle_measure (the same battle, offline), it prints rows of numbers, here for the host and for each client.
##
## How it works: run with no --role, this process is only the coordinator. It starts a headless host of mass_battle_sample.tscn as a
## separate Godot process, waits for it to load, then starts the clients, each joining it over 127.0.0.1, also headless. Each one
## writes its rows into its own log file (Windows doesn't pass a child's output on), and when they're all done the coordinator prints
## them, host first. The games run in real time, as playing does, so slow ticks and late snapshots happen as they would in play;
## headless means nothing is drawn, so a windowed game adds drawing on top.
##
## Run from the project folder (about 2.5 minutes with the defaults):
##   godot --headless --path . "res://assets/scripts/samples/tests/mass_battle_net_measure.tscn" -- --size=50 --seconds=120
## Settings, after "--":
##   --size=N        pawns a faction (50)
##   --seconds=N     how long each client plays, in real seconds (120); the host runs a little longer
##   --clients=N     how many clients join (1)
##   --every=N       seconds between rows (5)
##   --spectate      Claude 2026-11-16: each client lets go of its pawn 3 s after joining (V), so it controls nothing and acknowledges
##                   snapshots with ACK packets of their own (it used to get every snapshot in full)
##   --host-window   Claude 2026-11-16: runs the host in a window, so its rows include drawing, as when playing (the clients stay headless)
##   --spawn-distance=N  Claude 2026-11-16: passed on to the sample: the factions start N m from the middle (300). 40 is the quick
##                   peak-capacity test: they meet within seconds
## Anything else is passed on to every machine, so the sample's own settings work too: --near-middle, --tick-rate=30, --no-record.
##
## Each row, per machine, is diagnostics v0's summary over those seconds (DiagnosticsManager.get_summary):
##   line 1: the frame, how many ticks a frame, ticks run and dropped a second, the tick's cost and its share of the budget, the load step
##   line 2: the tick's parts in ms a tick: input (with the AI), simulate, record, then the network's: reading snapshots (in), correcting
##           this client's own pawns (reconcile), placing the server's pawns (remote pawns), and sending snapshots or inputs
##   line 3 (Claude 2026-11-16): the server's tick rate, how fast it really ran, and its load and load step, as this machine sees it
##   line 4: the connection: KB a second each way, snapshots a second and their average size, the round trip and packet loss ENet
##           measures, how long since anything arrived, and corrections, resyncs and interpolation underruns on a client
## A connection that ends is reported when it does, with why (NetworkSession.connection_ended), and each machine ends with its totals.
##
## Test code: it reaches into the sample (_port, _host, _join) the way mass_battle_measure does (docs/TEST_AND_DEBUG_CODE.md).
extends Node

const SCENE := "res://assets/scripts/samples/tests/mass_battle_net_measure.tscn"
const ARENA_SCENE := "res://assets/scenes/samples/mass_battle_sample.tscn"
## Lines a machine prints for the coordinator start with this, so they can be picked out of its log among Godot's own lines.
const ROW_MARK := "[measure] "
## Seconds the host gets to load the level and start hosting before the clients start.
const HOST_HEAD_START := 6.0
## Seconds the host keeps running after the clients' time, so they finish and leave before it stops.
const HOST_EXTRA := 8.0

var _role := "" # empty: the coordinator; "host" or "client": a machine
var _size := 50
var _seconds := 120
var _clients := 1
var _every := 5
var _port := 0
var _pass_on := PackedStringArray() # settings for the machines that the coordinator doesn't use itself
var _ended := false # client: its connection has ended
var _host_window := false # Claude 2026-11-16


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			_role = argument.trim_prefix("--role=")
		elif argument.begins_with("--size="):
			_size = int(argument.trim_prefix("--size="))
		elif argument.begins_with("--seconds="):
			_seconds = int(argument.trim_prefix("--seconds="))
		elif argument.begins_with("--clients="):
			_clients = maxi(int(argument.trim_prefix("--clients=")), 1)
		elif argument.begins_with("--every="):
			_every = maxi(int(argument.trim_prefix("--every=")), 1)
		elif argument.begins_with("--port="):
			_port = int(argument.trim_prefix("--port="))
		elif argument == "--host-window": # Claude 2026-11-16
			_host_window = true
		else:
			_pass_on.append(argument)
	if _role == "":
		await _coordinate()
	else:
		await _play()


# --- The coordinator ---------------------------------------------------------------------------------

func _coordinate() -> void:
	# A port of this run's own, so two runs at once can't join each other's games (NetRun's rule).
	_port = NetRun.first_port() + 7
	var folder := ProjectSettings.globalize_path("user://net_test/mass_battle/%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(folder)
	print("--- Mass battle over the network: %d a faction, a host and %d client%s, %d s, on port %d ---" % [_size, _clients, "" if _clients == 1 else "s", _seconds, _port])
	var names: Array[String] = ["host"]
	for i in _clients:
		names.append("client_%d" % (i + 1))
	var pids := {}
	for machine in names:
		var role := "host" if machine == "host" else "client"
		var log_path := folder.path_join(machine + ".log")
		DirAccess.remove_absolute(log_path)
		var seconds := _seconds + HOST_HEAD_START + HOST_EXTRA if role == "host" else float(_seconds)
		var arguments := PackedStringArray(["--headless", "--log-file", log_path, "--path", ProjectSettings.globalize_path("res://"), SCENE, "--",
			"--role=" + role, "--port=%d" % _port, "--size=%d" % _size, "--seconds=%d" % ceili(seconds), "--every=%d" % _every])
		arguments.append_array(_pass_on)
		if role == "host" and _host_window: # Claude 2026-11-16
			arguments.remove_at(0) # "--headless"
		pids[machine] = OS.create_process(OS.get_executable_path(), arguments, false)
		if role == "host":
			await get_tree().create_timer(HOST_HEAD_START).timeout
	# Wait for every machine, with room for loading; any still running after that is stopped and said to be.
	var deadline := Time.get_ticks_msec() + int((_seconds + HOST_EXTRA + 60.0) * 1000.0)
	while Time.get_ticks_msec() < deadline and pids.values().any(func(pid: int) -> bool: return OS.is_process_running(pid)):
		await get_tree().create_timer(0.5).timeout
	for machine in names:
		if OS.is_process_running(pids[machine]):
			OS.kill(pids[machine])
			print("(%s didn't finish in time and was stopped)" % machine)
	for machine in names:
		_print_machine(machine, folder.path_join(machine + ".log"))
	print("--- logs: %s ---" % folder)
	get_tree().quit(0)


## A machine's rows from its log, and any script errors in it.
func _print_machine(machine: String, log_path: String) -> void:
	print("")
	print("=== %s ===" % machine)
	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		print("(no log: it didn't start)")
		return
	var errors := 0
	while not file.eof_reached():
		var line := file.get_line()
		if line.begins_with(ROW_MARK):
			print(line.trim_prefix(ROW_MARK))
		elif line.contains("SCRIPT ERROR"):
			errors += 1
			if errors <= 5:
				print("  ! " + line)
	if errors > 0:
		print("  %d script errors" % errors)


# --- A machine: the host or a client ----------------------------------------------------------------

func _play() -> void:
	var diagnostics := GameMode.get_module(DiagnosticsManager) as DiagnosticsManager
	if diagnostics == null:
		_row("no DiagnosticsManager: check the project setting project_base/game_mode/modules")
		get_tree().quit(1)
		return
	NetworkSession.connection_ended.connect(_on_connection_ended)
	var arena: Node = load(ARENA_SCENE).instantiate()
	arena.team_size = _size
	add_child(arena)
	await get_tree().physics_frame
	arena._port = _port # the sample's own setting, normally from its --port=; set here because its command line is read a frame later
	if _role == "host":
		arena._host()
	else:
		arena._join("127.0.0.1")
	# Claude 2026-11-16: and the spawn distance (the sample's --spawn-distance=)
	_row("%s, %d a faction, spawns %.0f m out, %d ticks a second, %s" % [_role, _size, arena.spawn_distance, TickDriver.get_tick_rate(), " ".join(_pass_on) if not _pass_on.is_empty() else "no extra settings"])
	var started := Time.get_ticks_msec()
	var next_row := started + _every * 1000
	var spectate_at := started + 3000 if _role == "client" and _pass_on.has("--spectate") else -1 # Claude 2026-11-16
	while Time.get_ticks_msec() - started < _seconds * 1000 and not _ended:
		await get_tree().process_frame
		if spectate_at > 0 and Time.get_ticks_msec() >= spectate_at:
			spectate_at = -1
			arena._go_to_overview()
			_row("let go of its pawn (V): spectating, controlling nothing")
		if Time.get_ticks_msec() >= next_row:
			next_row += _every * 1000
			@warning_ignore("integer_division") # whole seconds on purpose
			_print_row((Time.get_ticks_msec() - started) / 1000, diagnostics.get_summary(_every))
	_print_totals()
	NetworkSession.leave()
	await get_tree().physics_frame
	get_tree().quit(0)


func _print_row(at_second: int, s: Dictionary) -> void:
	var parts: Dictionary = s.tick_parts
	var part := func(key: String) -> float: return float(parts.get(key, 0.0))
	_row("%4ds  %s  pawns %d, dead %d   frame %.1f ms (%.0f fps) = physics %.1f (%.2f steps) + scripts %.1f + rest %.1f   ticks/s %.0f, dropped/s %.1f   tick %.2f ms (%d%% of the budget)   load step %d, AI every tick/2nd/4th %s" % [
		at_second, s.role, s.pawns, s.dead, s.frame_ms, s.fps, s.physics_ms, s.steps_per_frame, s.scripts_ms, s.rest_ms, s.ticks_per_second, s.dropped_per_second, s.tick_ms,
		int(100.0 * s.tick_ms * TickDriver.get_tick_rate() / 1000.0), s.load_step, DiagnosticsManager.steps_text(s.step_counts)])
	_row("       ms a tick: input+AI %.2f, simulate %.2f, record %.2f | snapshots in %.2f, reconcile %.2f, remote pawns %.2f | send snapshots %.2f, send inputs %.2f" % [
		part.call("input") + part.call("capture"), part.call("simulate"), part.call("record"), part.call("flush"), part.call("reconcile"), part.call("remote"),
		part.call("send_snapshots"), part.call("send_inputs")])
	_row("       " + DiagnosticsManager.server_text(s.get("server", {}))) # Claude 2026-11-16: the server's tick rate and load, as this machine sees it
	if s.has("net"):
		_row("      " + DiagnosticsManager.net_text(s).trim_prefix(" | "))
	else:
		_row("       net: not connected")


func _print_totals() -> void:
	var stats: Dictionary = NetworkSession.stats
	# Claude 2026-11-16 (audit): the average as diagnostics works it out (DiagnosticsManager.average_snapshot_kb): a client's average
	# snapshot, from what was sent to clients on the host and what arrived on a client.
	var host := _role == "host"
	var average := DiagnosticsManager.average_snapshot_kb(stats.snapshot_bytes if host else stats.snapshot_bytes_received, stats.snapshots_sent if host else stats.snapshots_received)
	_row("totals: %.1f MB sent, %.1f MB received, %d snapshots %s (%.1f KB on average), largest packet sent %.1f KB, received %.1f KB" % [
		stats.bytes_sent / 1048576.0, stats.bytes_received / 1048576.0,
		stats.snapshots_sent if host else stats.snapshots_received, "sent" if host else "received", average,
		stats.largest_packet_sent / 1024.0, stats.largest_packet_received / 1024.0])
	if _role == "client":
		_row("        corrections %d (worst %.2f m), resyncs %d, interpolation underruns %d" % [stats.corrections, stats.correction_worst, stats.resyncs, stats.interpolation_underruns])


func _on_connection_ended(peer: int, reason: String, details: Dictionary) -> void:
	_row("connection: " + DiagnosticsManager.connection_ended_text(peer, reason, details)) # Claude 2026-11-16 (audit): the shared wording
	if _role == "client":
		_ended = true


## One line for the coordinator to pick out of this machine's log.
func _row(text: String) -> void:
	print(ROW_MARK + text)
