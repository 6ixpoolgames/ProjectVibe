# Written by Claude (claude-opus-5-5), 2026-11-16. History: diagnostics/CHANGELOG.md.
## Diagnostics v0: measures every frame, keeps logs, feeds the replay and shows the panels (docs/diagnostics/DIAGNOSTICS_SPEC.md).
##
## A GameMode module, listed by the project setting project_base/game_mode/modules, so the base never names it
## (docs/TEST_AND_DEBUG_CODE.md). It ships in release builds too, the owner's call, for bug reports (session logs, captures and
## replays from players' machines): the setting's .release override lists it as well. A game can leave it out of either list.
## [br]
## What it does, every frame, wherever the game runs (the editor, a window, headless):
## [br]- Measures the frame: the physics steps (all of this frame's ticks), every node's _process, and the rest (drawing the last frame,
##   and waiting for the screen), with timestamps from a helper that runs first and this module running last. A frame is counted from
##   the end of the last frame's scripts to the end of this one's, so a slow frame's time and its breakdown stay together (Godot's
##   delta would put the time on the next frame). Plus TickDriver's phases, every [PerfScopes] timing, drawing on the CPU and GPU, draw
##   calls, and memory, object, node and orphan-node counts (a leak shows as a count that only climbs).
## [br]- Keeps the last [member history_seconds] of frames in memory, and every frame over budget as a spike, with its full breakdown.
## [br]- Hands each frame to the replay recording ([ReplayDiagnosticsChannel]), so one file holds the game and what it cost.
## [br]- Writes a session log per instance (user://diagnostics/sessions/): a header saying how it was run, a summary every
##   [member log_every_seconds], every spike, and every warning and error, rate-limited.
## [br]- Starts a replay recording when a game starts and none is running (hosting, joining, or a player taking a pawn offline), so
##   recordings are always on, the owner's call.
## [br]- Feeds the editor's Debugger > Monitors with its main numbers, for live graphs when running from the editor.
## [br]- Shows panels, one key each ([DiagnosticsPanels]), and takes captures (F12).
## [br]
## Reading it from code: [code]GameMode.get_module(DiagnosticsManager)[/code] (not a named line on GameMode, since the base never
## names it).
## [codeblock]
## get_summary(seconds)  # averages over the last seconds; the keys are listed at get_summary
## get_frames()          # the history, oldest first; get_spikes(), the spikes, newest last
## get_log_lines()       # the warnings and errors so far, as [level, text, where, count]
## capture()             # saves a capture folder now, and returns its path
## [/codeblock]
# REFACTOR: one class does several jobs: measuring frames, the session log, captures, the editor's monitors, starting recordings and
# the window's title. Splitting out the session log and captures would make each easier to read and to swap. Extensible.
# See CHANGELOG.md.
class_name DiagnosticsManager
extends GameModeModule

## How much history is kept in memory, in seconds.
@export_range(1.0, 300.0, 1.0, "or_greater") var history_seconds := 30.0
## A frame is a spike when it takes longer than the tick's budget times this (1.2: over 20 ms at 60 ticks a second). Not much less:
## with vsync on, ordinary frames measure a millisecond either side of 16.7 ms, and would all count.
@export_range(1.0, 4.0, 0.05) var spike_over_budget := 1.2
## How many spikes are kept, newest last.
@export_range(1, 1000, 1, "or_greater") var spikes_kept := 50
## How often a summary line goes into the session log, in seconds.
@export_range(1.0, 600.0, 1.0, "or_greater") var log_every_seconds := 5.0
## How many times one warning or error is written out in full; after that, it's counted and the count goes in the next summary.
@export_range(1, 100, 1, "or_greater") var repeats_logged := 3
## Where session logs and captures go.
@export var folder := "user://diagnostics"
## On, a run with no display (a test, or a dedicated server) writes its session logs and captures into folder/headless instead, with its own logs_kept, so the many headless runs
## never push out the logs of games played in a window.
@export var headless_runs_apart := true
## How many session logs to keep. The oldest are deleted when a session starts.
@export_range(1, 1000, 1, "or_greater") var logs_kept := 30

var _driver: Node = null
var _session: Node = null
var _recorder: ReplayRecorder = null
var _channel := ReplayDiagnosticsChannel.new()
var _logger := DiagnosticsLogger.new()
var _panels: DiagnosticsPanels = null
var _marker: Node = null
var _frames: Array = [] # records, oldest first (see ReplayDiagnosticsChannel.add_frame for the keys, plus "time" and "ticks")
var _spikes: Array = []
var _frame_number := 0
var _first_physics_usec := 0 # when this frame's first physics step started, or 0 before one
var _physics_steps := 0
var _process_start_usec := 0
var _last_end_usec := 0 # when the last frame's scripts finished
var _last_tick := -1
var _last_dropped := 0
var _log_file: FileAccess = null
var _log_path := ""
var _next_log_msec := 0
var _messages := {} # text -> [level, text, where, times seen, times written in full, times when last counted in the log]
var _message_order: Array = [] # texts, in the order they first came
var _monitor_ids: Array[StringName] = []
var _last_summary := {}
var _role := "offline"
# The session's counters at the last frame, so each frame records what it added.
var _last_net := {} # counter index -> its value at the last frame
# The server's tick at the last frame: this machine's own offline or hosting, the newest snapshot's on a client. Each frame records
# how far it moved ("server_ticks").
var _last_server_tick := -1
# The session's counters come from NetworkSession.COUNTING_STATS (no hard-coded names, the owner's call), each kept in a frame's
# record as "net_<name>"; the key names are made once here, not every frame.
var _net_counters: Array[String] = []
var _net_keys: Array[String] = []


# The helper that notes when each frame's physics and process start: it runs before anything else in both.
class FrameStartMarker extends Node:
	var manager: DiagnosticsManager

	func _init() -> void:
		process_priority = -1000000
		process_physics_priority = -1000000

	func _physics_process(_delta: float) -> void:
		if manager._first_physics_usec == 0:
			manager._first_physics_usec = Time.get_ticks_usec()
		manager._physics_steps += 1

	func _process(_delta: float) -> void:
		manager._process_start_usec = Time.get_ticks_usec()


func _init() -> void:
	process_priority = 1000000 # last in each frame's process, for the frame timings
	set_physics_process(false)


func _on_module_added(game_mode: GameModeSingleton) -> void:
	_driver = get_node_or_null("/root/TickDriver")
	_session = get_node_or_null("/root/NetworkSession")
	if _session: # the counters the session publishes, and their record keys
		_net_counters.assign(NetworkSessionSingleton.COUNTING_STATS)
		for counter in _net_counters:
			_net_keys.append("net_" + counter)
	PerfScopes.enabled = true
	if _driver:
		_driver.profile_enabled = true
		_driver.reset_profile()
		_last_tick = _driver.tick
		_last_dropped = _driver.dropped_ticks
	OS.add_logger(_logger)
	_marker = FrameStartMarker.new()
	_marker.manager = self
	add_child(_marker)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_panels = DiagnosticsPanels.new()
	_panels.manager = self
	add_child(_panels)
	_add_monitors()
	_open_log()
	# The replay recorder is a module too; it may come before or after this one.
	game_mode.module_added.connect(_on_other_module)
	_hook_recorder(game_mode.replay_recorder)
	var possession: PossessionCoordinator = game_mode.possession_coordinator
	if possession:
		possession.possessed.connect(_on_possessed)
	if _session:
		_session.hosted.connect(func() -> void: _set_role("host"))
		_session.joined.connect(func() -> void: _set_role("client"))
		_session.disconnected.connect(func() -> void: _set_role("offline"))
		_session.connection_ended.connect(_on_connection_ended)
	_update_title()


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	PerfScopes.enabled = false
	if _driver:
		_driver.profile_enabled = false
	OS.remove_logger(_logger)
	_remove_monitors()
	if game_mode.module_added.is_connected(_on_other_module):
		game_mode.module_added.disconnect(_on_other_module)
	_close_log()


func _exit_tree() -> void:
	# The game is closing: everything the engine holds on to that points back here is handed back first.
	OS.remove_logger(_logger)
	_remove_monitors()
	_close_log()


func _remove_monitors() -> void:
	for id in _monitor_ids:
		if Performance.has_custom_monitor(id):
			Performance.remove_custom_monitor(id)
	_monitor_ids.clear()


# --- Every frame ---


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_ms := (now - _last_end_usec) / 1000.0 if _last_end_usec > 0 else delta * 1000.0
	_last_end_usec = now
	var record := {"frame": _frame_number, "time": Time.get_ticks_msec() / 1000.0, "frame_ms": frame_ms, "steps": _physics_steps}
	_frame_number += 1
	record["physics_ms"] = (_process_start_usec - _first_physics_usec) / 1000.0 if _first_physics_usec > 0 and _process_start_usec > _first_physics_usec else 0.0
	record["scripts_ms"] = (now - _process_start_usec) / 1000.0 if _process_start_usec > 0 else 0.0
	record["rest_ms"] = maxf(record.frame_ms - record.physics_ms - record.scripts_ms, 0.0)
	_first_physics_usec = 0
	_physics_steps = 0
	var viewport := get_viewport().get_viewport_rid()
	record["render_cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(viewport)
	record["render_gpu_ms"] = RenderingServer.viewport_get_measured_render_time_gpu(viewport)
	record["draw_calls"] = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	record["objects"] = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	record["nodes"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	record["orphans"] = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	record["memory_kb"] = int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1024.0)
	# The scopes: PerfScopes' own, plus TickDriver's phases and the network's parts as "tick." names.
	var scopes := PerfScopes.take_frame()
	if _driver:
		var profile: Dictionary = _driver.profile
		# Only the times, not the counts (rollbacks, rollback_ticks). The number of rollbacks is the rollback time's call count, as for
		# any scope.
		for part: Variant in profile:
			if TickDriverSingleton.PROFILE_COUNTS.has(String(part)) or int(profile[part]) <= 0:
				continue
			var calls: int = maxi(1, int(profile["rollbacks"])) if String(part) == "rollback" else 1
			scopes[StringName("tick." + String(part))] = [int(profile[part]), calls]
		_driver.reset_profile()
		record["ticks"] = _driver.tick - _last_tick
		_last_tick = _driver.tick
		record["dropped"] = _driver.dropped_ticks - _last_dropped
		_last_dropped = _driver.dropped_ticks
		record["load_step"] = _driver.load_step # the load ladder (pawn spec 8.21)
	# How many AI pawns run every tick, every 2nd and every 4th (AIActivationManager).
	var game_mode: Node = get_node_or_null(^"/root/GameMode")
	var activation: AIActivationManager = game_mode.ai_activation_manager if game_mode else null
	if activation:
		record["step_counts"] = activation.get_step_counts()
	_record_network(record)
	_record_server_ticks(record)
	record["scopes"] = scopes
	_frames.append(record)
	var oldest: float = record.time - history_seconds
	while not _frames.is_empty() and _frames[0].time < oldest:
		_frames.pop_front()
	if _is_spike(record):
		_spikes.append(record)
		if _spikes.size() > spikes_kept:
			_spikes.pop_front()
		_write_line("[spike] " + _spike_text(record))
	if _recorder and _recorder.is_recording():
		_channel.add_frame(record)
	_take_messages()
	if Time.get_ticks_msec() >= _next_log_msec:
		_next_log_msec = Time.get_ticks_msec() + int(log_every_seconds * 1000.0)
		_last_summary = _summary(log_every_seconds)
		_write_line(summary_text(_last_summary))
		_write_repeat_counts()


func _is_spike(record: Dictionary) -> bool:
	if _frame_number < 30:
		return false # loading
	var budget: float = 1000.0 / (_driver.get_tick_rate() if _driver else 60)
	return record.frame_ms > budget * spike_over_budget


# --- Reading it ---


## The history, oldest first.
func get_frames() -> Array:
	return _frames


## The spikes kept, newest last.
func get_spikes() -> Array:
	return _spikes


## Every warning and error so far, as [level, text, where, count], in the order they first came.
func get_log_lines() -> Array:
	var out: Array = []
	for text: String in _message_order:
		var entry: Array = _messages[text]
		out.append([entry[0], entry[1], entry[2], entry[3]])
	return out


## The session log's path.
func get_log_path() -> String:
	return _log_path


## Averages over the last seconds of history, as a Dictionary.
##
## Its keys:
## [br]- The frame: seconds, frames, fps, frame_ms, physics_ms, scripts_ms, rest_ms, steps_per_frame, frame_worst_ms, over_60_percent
##   (frames over 20 ms), over_30_percent (over 34 ms), render_cpu_ms, render_gpu_ms, draw_calls, animation_ms (the animation
##   category: every "animation." scope, ms a frame).
## [br]- Ticks: ticks_per_second, dropped_per_second, load_step, step_counts (AI pawns running every tick, 2nd and 4th), tick_ms
##   (TickDriver's phases a tick), tick_parts (each phase and network part -> ms a tick).
## [br]- scopes: name -> [ms a frame, calls a frame], most expensive first.
## [br]- Counts: objects, nodes, orphans, memory_mb, pawns, dead, frozen; and role, window, vsync.
## [br]- server: tick_rate (what it's set to), ticks_per_second (how fast its ticks really went: this machine's own offline or hosting,
##   measured from snapshots on a client), load_percent and load_step (the load ladder's; on a client, as the server's snapshots report
##   them, -1 before any). For profiling on different hardware, the owner's request.
## [br]- net, while in a session: sent_kb_s, received_kb_s, snapshots_per_second, snapshot_kb (the average snapshot: as sent on a
##   server, as received on a client), largest_sent_kb and largest_received_kb (the biggest packets since the start),
##   corrections_per_second, resyncs, underruns_per_second, and the worst connection's rtt_ms, loss_percent and seconds_since_heard.
func get_summary(seconds := 1.0) -> Dictionary:
	return _summary(seconds)


## "a/b/c" for how many AI pawns run every tick, every 2nd and every 4th, or "-" without the counts.
static func steps_text(counts: Variant) -> String:
	if not (counts is Dictionary) or counts.is_empty():
		return "-"
	return "%d/%d/%d" % [counts.get(1, 0), counts.get(2, 0), counts.get(4, 0)]


func _summary(seconds: float) -> Dictionary:
	var out := {"seconds": seconds, "role": _role, "window": "%dx%d" % [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"vsync": ["off", "on", "adaptive", "mailbox"][DisplayServer.window_get_vsync_mode()] if not RunEnvironment.is_headless() else "headless"}
	var since: float = (_frames[-1].time if not _frames.is_empty() else 0.0) - seconds
	var count := 0
	var sums := {"frame_ms": 0.0, "physics_ms": 0.0, "scripts_ms": 0.0, "rest_ms": 0.0, "steps": 0.0, "render_cpu_ms": 0.0,
		"render_gpu_ms": 0.0, "ticks": 0.0, "dropped": 0.0}
	for key in _net_keys: # each frame's network counts, summed like the rest
		sums[key] = 0.0
	sums["server_ticks"] = 0.0
	var worst := 0.0
	var over_60 := 0
	var over_30 := 0
	var scope_sums := {}
	var tick_total := 0.0
	var last: Dictionary = {}
	for i in range(_frames.size() - 1, -1, -1):
		var record: Dictionary = _frames[i]
		if record.time <= since:
			break
		if last.is_empty():
			last = record
		count += 1
		for key: String in sums:
			sums[key] += float(record.get(key, 0.0))
		worst = maxf(worst, record.frame_ms)
		# REFACTOR: "late" and "very late" are fixed at 20 and 34 ms (60 and 30 fps), while spikes follow the tick rate and
		# spike_over_budget; the panels and the replay viewer's strip repeat the same numbers. Settings, or the frame budget, would let a
		# game with another target set them. Designer friendly. See CHANGELOG.md.
		if record.frame_ms > 20.0: # late: a missed 1/60 s, allowing for a millisecond of jitter either side
			over_60 += 1
		if record.frame_ms > 34.0:
			over_30 += 1
		for scope: StringName in record.scopes:
			var entry: Array = record.scopes[scope]
			var sum: Variant = scope_sums.get(scope)
			if sum == null:
				scope_sums[scope] = [float(entry[0]), float(entry[1])]
			else:
				sum[0] += entry[0]
				sum[1] += entry[1]
	var frames := maxf(count, 1)
	out["frames"] = count
	for key: String in ["frame_ms", "physics_ms", "scripts_ms", "rest_ms", "render_cpu_ms", "render_gpu_ms"]:
		out[key] = sums[key] / frames
	out["steps_per_frame"] = sums.steps / frames
	out["fps"] = 1000.0 / out.frame_ms if out.frame_ms > 0.0 else 0.0
	out["frame_worst_ms"] = worst
	out["over_60_percent"] = 100.0 * over_60 / frames
	out["over_30_percent"] = 100.0 * over_30 / frames
	var span := maxf(seconds, 0.001)
	out["ticks_per_second"] = sums.ticks / span
	out["dropped_per_second"] = sums.dropped / span
	out["load_step"] = int(last.get("load_step", 1)) # the load ladder (pawn spec 8.21)
	out["step_counts"] = last.get("step_counts", {})
	for key: String in ["draw_calls", "objects", "nodes", "orphans"]:
		out[key] = int(last.get(key, 0))
	out["memory_mb"] = last.get("memory_kb", 0) / 1024.0
	# Scopes as ms a frame, most expensive first. The tick phases are also given a tick, for comparing with the tick's budget.
	var names := scope_sums.keys()
	names.sort_custom(func(a: StringName, b: StringName) -> bool: return scope_sums[a][0] > scope_sums[b][0])
	var scopes := {}
	for scope: StringName in names:
		scopes[scope] = [scope_sums[scope][0] / 1000.0 / frames, scope_sums[scope][1] / frames]
	out["scopes"] = scopes
	# The animation category (the owner's request), worked out here rather than every frame: every "animation." scope added up, ms a
	# frame. Animation runs once a rendered frame, in the scripts part of it. A new animation system joins it by naming its scopes
	# "animation.something".
	out["animation_ms"] = _animation_usec(scope_sums) / 1000.0 / frames
	var ticks := maxf(sums.ticks, 1.0)
	for part in ["input", "capture", "simulate", "record", "before_tick", "after_tick"]:
		var entry: Variant = scope_sums.get(StringName("tick." + part))
		tick_total += (entry[0] if entry != null else 0.0)
	out["tick_ms"] = tick_total / 1000.0 / ticks
	# Each of TickDriver's phases, and the network's parts, as ms a tick.
	var tick_parts := {}
	for scope: StringName in scope_sums:
		if String(scope).begins_with("tick."):
			tick_parts[String(scope).trim_prefix("tick.")] = scope_sums[scope][0] / 1000.0 / ticks
	out["tick_parts"] = tick_parts
	var pawns := 0
	var dead := 0
	var frozen := 0
	for node in get_tree().get_nodes_in_group(Pawn.GROUP): # the list of all pawns
		var pawn := node as Pawn
		if pawn:
			pawns += 1
			if pawn.is_dead():
				dead += 1
			if pawn.is_frozen():
				frozen += 1
	out["pawns"] = pawns
	out["dead"] = dead
	out["frozen"] = frozen
	if _role != "offline" and _session:
		out["net"] = _net_summary(sums, span)
	out["server"] = _server_summary(sums.server_ticks / span)
	return out


# The server's tick rate, how fast it really ran, and its load, for a summary (the owner's request). Also what get_server_ticks()
# gives, for a game's own readout.
func _server_summary(ticks_per_second: float) -> Dictionary:
	var client: bool = _session != null and _session.is_client()
	var out := {"tick_rate": _driver.get_tick_rate() if _driver else 0, "ticks_per_second": ticks_per_second, "load_percent": -1, "load_step": -1}
	if client:
		out.load_percent = _session.server_load_percent
		out.load_step = _session.server_load_step
	elif _driver:
		out.load_percent = roundi(_driver.load_average * 100.0)
		out.load_step = _driver.load_step
	return out


## The server's tick rate over the last seconds, as in a summary's "server" (tick_rate, ticks_per_second, load_percent, load_step).
##
## Cheap enough for every frame: it only adds up the newest frames' tick counts, unlike [method get_summary]. A game's HUD can show
## it; the arena samples' status line does ([method server_text]).
func get_server_ticks(seconds := 1.0) -> Dictionary:
	var since: float = (_frames[-1].time if not _frames.is_empty() else 0.0) - seconds
	var ticks := 0.0
	for i in range(_frames.size() - 1, -1, -1):
		var record: Dictionary = _frames[i]
		if record.time <= since:
			break
		ticks += float(record.get("server_ticks", 0))
	return _server_summary(ticks / maxf(seconds, 0.001))


## A summary's "server" as a short line: "server 60 ticks/s, running 59.8, load 63%, step 1".
static func server_text(server: Dictionary) -> String:
	if server.is_empty():
		return ""
	var text := "server %d ticks/s, running %.1f" % [server.get("tick_rate", 0), server.get("ticks_per_second", 0.0)]
	if int(server.get("load_percent", -1)) >= 0:
		text += ", load %d%%, step %d" % [server.load_percent, server.load_step]
	return text


# How far the server's tick moved this frame, into the frame's record. Offline and hosting that's this machine's own ticks (the
# record's "ticks"); on a client, how far the newest snapshot's tick moved. A jump back (a new session, or a client's first snapshot)
# counts as nothing.
func _record_server_ticks(record: Dictionary) -> void:
	if not (_session and _session.is_client()):
		record["server_ticks"] = record.get("ticks", 0)
		_last_server_tick = -1
		return
	var now: int = _session.get_newest_snapshot_tick()
	record["server_ticks"] = maxi(now - _last_server_tick, 0) if _last_server_tick >= 0 and now >= 0 else 0
	_last_server_tick = now


# The animation category's microseconds in a set of scopes (name -> [microseconds, calls]).
static func _animation_usec(scopes: Dictionary) -> float:
	var total := 0.0
	for scope: StringName in scopes:
		if String(scope).begins_with("animation."):
			total += float(scopes[scope][0])
	return total


# The network part of a summary, from the frames' counts (sums) over span seconds, and the connections' latest numbers. Snapshots a
# second are those encoded on a server and those received on a client. Their average size counts like with like: on a server the
# snapshots sent (one per client) and the bytes they carried, on a client the snapshots received and their bytes.
func _net_summary(sums: Dictionary, span: float) -> Dictionary:
	var server: bool = _session.is_server()
	var snapshots: float = sums.net_snapshots_encoded if server else sums.net_snapshots_received
	var net := {"sent_kb_s": sums.net_bytes_sent / 1024.0 / span, "received_kb_s": sums.net_bytes_received / 1024.0 / span,
		"snapshots_per_second": snapshots / span,
		"snapshot_kb": average_snapshot_kb(sums.net_snapshot_bytes if server else sums.net_snapshot_bytes_received, sums.net_snapshots_sent if server else sums.net_snapshots_received),
		"largest_sent_kb": _session.stats.get("largest_packet_sent", 0) / 1024.0, "largest_received_kb": _session.stats.get("largest_packet_received", 0) / 1024.0,
		"corrections_per_second": sums.net_corrections / span, "resyncs": int(sums.net_resyncs), "underruns_per_second": sums.net_interpolation_underruns / span,
		"rtt_ms": -1, "loss_percent": -1.0, "seconds_since_heard": 0.0}
	var links: Dictionary = _session.get_link_stats()
	for peer: int in links:
		var link: Dictionary = links[peer]
		net.rtt_ms = maxi(net.rtt_ms, int(link.get("rtt_ms", -1)))
		net.loss_percent = maxf(net.loss_percent, float(link.get("loss_percent", -1.0)))
		net.seconds_since_heard = maxf(net.seconds_since_heard, float(link.get("seconds_since_heard", 0.0)))
	return net


## An average snapshot's size in KB, from bytes and how many snapshots carried them (0 with none). Shared with the
## networked measure, so both work it out the same way.
static func average_snapshot_kb(bytes: float, snapshots: float) -> float:
	return bytes / 1024.0 / snapshots if snapshots > 0.0 else 0.0


# What the session's counters added this frame, into the frame's record as "net_" keys. The counters only ever grow during a
# session, so the difference is this frame's; a new session starts them where they are. Nothing offline, where they don't change
# (the replay's diagnostics channel never reads these keys).
func _record_network(record: Dictionary) -> void:
	if _session == null or _role == "offline":
		_last_net.clear()
		return
	var stats: Dictionary = _session.stats
	for i in _net_counters.size():
		var now := float(stats[_net_counters[i]])
		record[_net_keys[i]] = maxf(now - float(_last_net.get(i, now)), 0.0)
		_last_net[i] = now


# A connection ended: why, and its last numbers, into the session log.
func _on_connection_ended(peer: int, reason: String, details: Dictionary) -> void:
	_write_line("[network] " + connection_ended_text(peer, reason, details))


## A NetworkSession.connection_ended as one line of text, shared with the networked measure.
static func connection_ended_text(peer: int, reason: String, details: Dictionary) -> String:
	if details.is_empty():
		return "%s ended: %s" % ["the session" if peer == 0 else "peer %d" % peer, reason]
	return "peer %d ended: %s (connected %.1f s, last heard from %.1f s before, round trip %d ms, packet loss %.1f%%)" % [
		peer, reason, details.get("seconds_connected", 0.0), details.get("seconds_since_heard", 0.0), details.get("rtt_ms", -1), details.get("loss_percent", -1.0)]


## The last summary written to the log (every [member log_every_seconds]), for a game's own readout. Nothing in the base reads it.
func get_last_summary() -> Dictionary:
	return _last_summary


# --- Replays: hooking in, and always on ---


func _on_other_module(module: GameModeModule) -> void:
	if module is ReplayRecorder:
		_hook_recorder(module)


func _hook_recorder(recorder: ReplayRecorder) -> void:
	if recorder == null or recorder == _recorder:
		return
	_recorder = recorder
	recorder.add_channel(_channel) # warns and does nothing if it's already recording; the next recording has it


# Always-on recordings (the owner's call): a game that starts without starting one gets one. The samples start theirs themselves.
# REFACTOR: a replay rule living in diagnostics. A game without DiagnosticsManager gets no always-on recordings; an always-on setting
# on ReplayRecorder would keep the rule with the recorder. Reusable. See CHANGELOG.md.
func _on_possessed(peer: int, _pawn: Pawn) -> void:
	if _session and _session.is_connected_to_session():
		return # hosting and joining are handled by their own signals
	if peer == 0 and _recorder and not _recorder.is_recording():
		_recorder.start_recording("host")


func _set_role(role: String) -> void:
	_role = role
	_write_line("[role] %s" % role)
	_update_title()
	if _recorder == null:
		return
	if role == "offline":
		return # the session ended; the recorder is stopped by whoever started it, or carries on offline
	if not _recorder.is_recording():
		_recorder.start_recording(role)


# The window's title says the role and the process, so several instances on one machine can be told apart.
# REFACTOR: a debugging convenience that also renames a shipped game's window ("Name - offline, process 1234"), since diagnostics
# ship in release builds. A setting, or debug builds only, would keep a game's own title. Designer friendly. See CHANGELOG.md.
func _update_title() -> void:
	if RunEnvironment.is_headless():
		return
	var base: String = ProjectSettings.get_setting("application/config/name", "Game")
	DisplayServer.window_set_title("%s - %s, process %d" % [base, _role, OS.get_process_id()])


# --- The session log ---


func _open_log() -> void:
	var sessions := _run_folder().path_join("sessions") # headless runs apart (headless_runs_apart)
	DirAccess.make_dir_recursive_absolute(sessions)
	var names: Array = Array(DirAccess.get_files_at(sessions)).filter(func(file_name: String) -> bool: return file_name.ends_with(".log"))
	names.sort()
	while names.size() >= logs_kept:
		DirAccess.remove_absolute(sessions.path_join(names.pop_front()))
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	_log_path = sessions.path_join("%s_%d.log" % [stamp, OS.get_process_id()])
	_log_file = FileAccess.open(_log_path, FileAccess.WRITE)
	if _log_file == null:
		return
	var version: Dictionary = Engine.get_version_info()
	_write_line("session %s, %s %s, Godot %s, %s build, from the editor's debugger: %s" % [Time.get_datetime_string_from_system(false, true),
		ProjectSettings.get_setting("application/config/name", ""), ProjectSettings.get_setting("application/config/version", ""),
		version.get("string", "?"), "debug" if OS.is_debug_build() else "release", "yes" if EngineDebugger.is_active() else "no"])
	_write_line("command line: %s | %s" % [" ".join(OS.get_cmdline_args()), " ".join(OS.get_cmdline_user_args())])
	_write_line("machine: %s, %d threads, %s, display %s, tick rate %d, job workers setting %d" % [OS.get_processor_name(),
		OS.get_processor_count(), RenderingServer.get_video_adapter_name(), DisplayServer.get_name(),
		_driver.get_tick_rate() if _driver else 0, TickJobs.get_worker_count_setting()])


# This run's folder: folder, or folder/headless for a run with no display (headless_runs_apart).
func _run_folder() -> String:
	if headless_runs_apart and RunEnvironment.is_headless():
		return folder.path_join("headless")
	return folder


func _close_log() -> void:
	if _log_file:
		_write_line("session ends")
		_log_file.close()
		_log_file = null


func _write_line(line: String) -> void:
	if _log_file:
		_log_file.store_line("%8.1fs %s" % [Time.get_ticks_msec() / 1000.0, line])
		_log_file.flush()


## A summary (get_summary) as one line of text, as the session log writes it.
func summary_text(n: Dictionary) -> String:
	var top := PackedStringArray()
	for scope: StringName in n.scopes:
		if top.size() >= 6:
			break
		top.append("%s %.2f" % [scope, n.scopes[scope][0]])
	return "[summary %.0fs] %s, %d fps, frame %.1f ms (worst %.0f, late >20 ms %.0f%%, very late >34 ms %.0f%%) = physics %.1f (%.2f steps) + scripts %.1f (animation %.1f) + rest %.1f | tick %.2f ms, %.0f ticks/s, dropped %.1f/s, load step %d, AI every tick/2nd/4th %s | draw CPU %.1f GPU %.1f, %d calls | memory %.0f MB, objects %d, nodes %d, orphans %d | pawns %d, dead %d, frozen %d | %s, vsync %s | top ms/frame: %s" % [
		n.seconds, n.role, n.fps, n.frame_ms, n.frame_worst_ms, n.over_60_percent, n.over_30_percent, n.physics_ms, n.steps_per_frame,
		n.scripts_ms, n.get("animation_ms", 0.0), n.rest_ms, n.tick_ms, n.ticks_per_second, n.dropped_per_second, n.load_step, DiagnosticsManager.steps_text(n.step_counts), n.render_cpu_ms, n.render_gpu_ms, n.draw_calls,
		n.memory_mb, n.objects, n.nodes, n.orphans, n.pawns, n.dead, n.frozen, n.window, n.vsync, ", ".join(top)] + " | " + server_text(n.get("server", {})) + net_text(n) # then the server's tick rate, and the network


## The network part of a summary line, or empty offline.
static func net_text(n: Dictionary) -> String:
	if not n.has("net"):
		return ""
	var net: Dictionary = n.net
	return " | net: sent %.0f KB/s, received %.0f KB/s, %.0f snapshots/s of %.1f KB, largest packet so far sent %.1f KB, received %.1f KB, round trip %d ms, loss %.1f%%, last heard %.1f s ago, corrections %.1f/s, resyncs %d, underruns %.1f/s" % [
		net.sent_kb_s, net.received_kb_s, net.snapshots_per_second, net.snapshot_kb, net.largest_sent_kb, net.largest_received_kb, net.rtt_ms, net.loss_percent,
		net.seconds_since_heard, net.corrections_per_second, net.resyncs, net.underruns_per_second]


func _spike_text(record: Dictionary) -> String:
	var names: Array = record.scopes.keys()
	names.sort_custom(func(a: StringName, b: StringName) -> bool: return record.scopes[a][0] > record.scopes[b][0])
	var top := PackedStringArray()
	for scope: StringName in names.slice(0, 5):
		top.append("%s %.2f" % [scope, record.scopes[scope][0] / 1000.0])
	return "frame %d: %.1f ms = physics %.1f (%d steps) + scripts %.1f + rest %.1f | top ms: %s" % [record.frame, record.frame_ms,
		record.physics_ms, record.steps, record.scripts_ms, record.rest_ms, ", ".join(top)]


# Warnings and errors from the logger: each one written in full repeats_logged times, then counted.
func _take_messages() -> void:
	var taken: Array = _logger.take_messages()
	for message: Array in taken[0]:
		var text: String = message[1]
		var entry: Variant = _messages.get(text)
		if entry == null:
			entry = [message[0], text, message[2], 0, 0, 0]
			_messages[text] = entry
			_message_order.append(text)
		entry[3] += 1
		if entry[4] < repeats_logged:
			entry[4] += 1
			_write_line("[%s] %s (%s)" % [message[0], text, message[2]])
			if _recorder and _recorder.is_recording():
				_channel.add_event("log", 0, {"level": message[0], "text": text, "count": entry[3]})
	if taken[1] > 0:
		_write_line("[log] %d more messages came too fast to keep" % taken[1])


# Messages seen more often than they were written out, and more often than when last counted here, get one line with their count.
func _write_repeat_counts() -> void:
	for text: String in _message_order:
		var entry: Array = _messages[text]
		if entry[3] > entry[4] and entry[3] > entry[5]:
			_write_line("[%s] repeated, %d times in all so far: %s" % [entry[0], entry[3], text.left(160)])
			entry[5] = entry[3]


# --- Captures (F12) ---


## Saves a capture now: a screenshot, the history as a table, the spikes, the warnings and errors, and where the replay is, in a folder
## of its own. Returns the folder's path.
func capture() -> String:
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var path := _run_folder().path_join("captures").path_join("%s_%d" % [stamp, OS.get_process_id()])
	DirAccess.make_dir_recursive_absolute(path)
	if not RunEnvironment.is_headless():
		var image := get_viewport().get_texture().get_image()
		if image:
			image.save_png(path.path_join("screenshot.png"))
	var table := FileAccess.open(path.path_join("frames.csv"), FileAccess.WRITE)
	if table:
		table.store_line("time,frame,frame_ms,physics_ms,scripts_ms,rest_ms,steps,ticks,render_cpu_ms,render_gpu_ms,draw_calls,objects,nodes,orphans,memory_kb,top_scopes")
		for record: Dictionary in _frames:
			table.store_line("%.3f,%d,%.2f,%.2f,%.2f,%.2f,%d,%d,%.2f,%.2f,%d,%d,%d,%d,%d,\"%s\"" % [record.time, record.frame, record.frame_ms,
				record.physics_ms, record.scripts_ms, record.rest_ms, record.steps, record.get("ticks", 0), record.render_cpu_ms,
				record.render_gpu_ms, record.draw_calls, record.objects, record.nodes, record.orphans, record.memory_kb,
				_spike_text(record).get_slice("top ms: ", 1)])
		table.close()
	var notes := FileAccess.open(path.path_join("capture.txt"), FileAccess.WRITE)
	if notes:
		var tick: int = _driver.tick if _driver else -1
		notes.store_line("capture at %s, tick %d" % [Time.get_datetime_string_from_system(false, true), tick])
		notes.store_line("replay: %s" % (_recorder.get_recording_path() if _recorder and _recorder.is_recording() else "(not recording)"))
		notes.store_line("session log: %s" % _log_path)
		notes.store_line("")
		notes.store_line(summary_text(_summary(5.0)))
		notes.store_line("")
		notes.store_line("spikes, newest last:")
		for record: Dictionary in _spikes:
			notes.store_line("  " + _spike_text(record))
		notes.store_line("")
		notes.store_line("warnings and errors:")
		for line: Array in get_log_lines():
			notes.store_line("  [%s] x%d %s (%s)" % [line[0], line[3], line[1], line[2]])
		notes.close()
	if _recorder and _recorder.is_recording():
		_channel.add_event("capture", 0, {"folder": path})
	_write_line("[capture] %s" % path)
	return path


# --- The editor's Debugger > Monitors ---


func _add_monitors() -> void:
	var monitors := {
		&"Diagnostics/Frame (ms)": func() -> float: return _last_frame(&"frame_ms"),
		&"Diagnostics/Physics (ms)": func() -> float: return _last_frame(&"physics_ms"),
		&"Diagnostics/Scripts (ms)": func() -> float: return _last_frame(&"scripts_ms"),
		&"Diagnostics/Animation (ms)": func() -> float: return _animation_usec(_frames[-1].scopes) / 1000.0 if not _frames.is_empty() else 0.0,
		&"Diagnostics/Physics steps": func() -> float: return _last_frame(&"steps"),
		&"Diagnostics/Objects": func() -> float: return _last_frame(&"objects"),
		&"Diagnostics/Nodes": func() -> float: return _last_frame(&"nodes"),
		&"Diagnostics/Orphan nodes": func() -> float: return _last_frame(&"orphans"),
		# the server's real tick rate, over the last second
		&"Diagnostics/Server ticks per second": func() -> float: return float(get_server_ticks(1.0).ticks_per_second),
	}
	for id: StringName in monitors:
		if not Performance.has_custom_monitor(id):
			Performance.add_custom_monitor(id, monitors[id])
			_monitor_ids.append(id)


func _last_frame(key: StringName) -> float:
	return float(_frames[-1].get(key, 0.0)) if not _frames.is_empty() else 0.0
