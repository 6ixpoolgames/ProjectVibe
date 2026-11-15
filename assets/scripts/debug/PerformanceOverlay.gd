## Written by Claude (claude-opus-5-5), 2026-11-15: an on-screen table of where the time goes, for stress samples such as the mass
## battle (the owner's request: see how close a big fight gets to the edge, and what streaming and freezing add). Not part of the base:
## a sample adds one, like AbilityDebugDraw.
##
## What it shows, averaged over the last refresh_seconds:
##   - frames a second, and how long Godot's last process and physics frames took
##   - a tick's cost by phase, from TickDriver's own timing (its profile): input and AI, simulate (abilities, gravity, move_and_slide,
##     hits), record (rollback state), and the rest, against the tick's budget (1000 / tick rate ms)
##   - how much of the physics frame is spent outside the ticks: the physics engine's own step, nav's tile building and path
##     searches (TerrainNavFeeder's tick_nav), and other nodes' _physics_process. Measured as the physics frame less the ticks in it.
##   - ticks dropped because a frame fell too far behind (TickDriver.dropped_ticks): the game slows down rather than freezing, and
##     this is how far it's fallen behind
##   - pawns: how many there are, how many the AI switch-off has frozen (AIActivationManager), how many are dead
##   - chunks: how many are built, how many wait to be built or removed, and how long chunk building took this frame and at worst
##   - any lines the sample adds (extra_text)
##
## While it's shown it switches TickDriver's timing on (profile_enabled), which costs a few microseconds a tick, and off again when it's
## hidden. get_numbers() gives the same numbers as a dictionary, for a script that prints a table instead.
##
## How to use it:
##   var overlay := PerformanceOverlay.new()
##   some_canvas_layer.add_child(overlay)
##   overlay.streamer = $World/ChunkStreamer    # optional: its chunk numbers
##   overlay.extra_text = func() -> String: return "my own line"
##   overlay.visible = false    # hides it and stops the timing
class_name PerformanceOverlay
extends Label

## How often the numbers are worked out again, in seconds.
@export_range(0.1, 5.0, 0.05, "or_greater") var refresh_seconds := 0.5
## Optional: a function returning more text, added under the table.
var extra_text: Callable
## Optional: the level's ChunkStreamer, for how many chunks wait to be built or removed and how long building takes.
var streamer: ChunkStreamer

var _numbers := {}
var _waited := 0.0
var _dropped_at_start := 0
var _process_ms_total := 0.0
var _physics_ms_total := 0.0
var _physics_ms_worst := 0.0
var _frames := 0


func _ready() -> void:
	position = Vector2(14, 120)
	var settings := LabelSettings.new()
	settings.font_size = 16
	settings.outline_size = 6
	settings.outline_color = Color.BLACK
	label_settings = settings
	_start_window()
	# GDScript note: visibility_changed fires whenever visible flips, so the timing follows it.
	visibility_changed.connect(_start_window)


func _exit_tree() -> void:
	TickDriver.profile_enabled = false


func _process(delta: float) -> void:
	if not visible:
		return
	# GDScript note: TIME_PROCESS and TIME_PHYSICS_PROCESS are how long the last process and physics frames took, in seconds.
	_process_ms_total += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_physics_ms_total += physics_ms
	_physics_ms_worst = maxf(_physics_ms_worst, physics_ms)
	_frames += 1
	_waited += delta
	if _waited < refresh_seconds:
		return
	_numbers = _work_out(_waited)
	text = _table(_numbers)
	if extra_text.is_valid():
		text += "\n" + String(extra_text.call())
	_start_window()


## The numbers last worked out, as a dictionary (empty before the first refresh). Keys: fps, process_ms, physics_ms,
## physics_worst_ms, outside_ticks_ms, ticks, input_ms, simulate_ms, record_ms, other_ms, tick_ms, budget_ms, dropped_per_second, pawns, frozen, dead,
## chunks_built, chunks_queued, unloads_queued, chunk_frame_ms, chunk_worst_ms.
func get_numbers() -> Dictionary:
	return _numbers


# Starts a new averaging window: timing on while shown, counts back to 0.
func _start_window() -> void:
	TickDriver.profile_enabled = visible
	TickDriver.reset_profile()
	_dropped_at_start = TickDriver.dropped_ticks
	_waited = 0.0
	_process_ms_total = 0.0
	_physics_ms_total = 0.0
	_physics_ms_worst = 0.0
	_frames = 0


func _work_out(seconds: float) -> Dictionary:
	var profile: Dictionary = TickDriver.profile
	var ticks: float = maxf(float(profile.get("ticks", 0)), 1.0)
	var input_us: float = profile.get("input", 0) + profile.get("capture", 0)
	var other_us: float = profile.get("before_tick", 0) + profile.get("after_tick", 0)
	var out := {
		"fps": Engine.get_frames_per_second(),
		"process_ms": _process_ms_total / maxf(_frames, 1),
		"physics_ms": _physics_ms_total / maxf(_frames, 1),
		"physics_worst_ms": _physics_ms_worst,
		"ticks": int(ticks),
		"input_ms": input_us / 1000.0 / ticks,
		"simulate_ms": float(profile.get("simulate", 0)) / 1000.0 / ticks,
		"record_ms": float(profile.get("record", 0)) / 1000.0 / ticks,
		"other_ms": other_us / 1000.0 / ticks,
		"budget_ms": 1000.0 / TickDriver.get_tick_rate(),
		"dropped_per_second": (TickDriver.dropped_ticks - _dropped_at_start) / seconds,
	}
	out["tick_ms"] = out["input_ms"] + out["simulate_ms"] + out["record_ms"] + out["other_ms"]
	# Ticks per physics frame: 1 when the tick rate is the physics rate, as here by default.
	var ticks_per_frame := float(profile.get("ticks", 0)) / maxf(_frames, 1) if Engine.get_frames_per_second() > 0 else 1.0
	out["outside_ticks_ms"] = maxf(out["physics_ms"] - out["tick_ms"] * maxf(ticks_per_frame, 1.0), 0.0)
	var pawns := 0
	var dead := 0
	for node in get_tree().get_nodes_in_group(TerrainBodyLifter.GROUP): # every pawn joins this group
		var pawn := node as Pawn
		if pawn:
			pawns += 1
			if pawn.is_dead():
				dead += 1
	out["pawns"] = pawns
	out["dead"] = dead
	out["frozen"] = GameMode.ai_activation_manager.get_inactive_count() if GameMode.ai_activation_manager else 0
	var built := 0
	for node in get_tree().get_nodes_in_group(TerrainGenerator.GROUP):
		if node is TerrainGenerator:
			built += (node as TerrainGenerator).get_loaded_chunks().size()
	out["chunks_built"] = built
	out["chunks_queued"] = 0
	out["unloads_queued"] = 0
	out["chunk_frame_ms"] = 0.0
	out["chunk_worst_ms"] = 0.0
	if is_instance_valid(streamer):
		var stats: Dictionary = streamer.get_stats()
		out["chunks_queued"] = stats["queued"]
		out["unloads_queued"] = stats["unload_queued"]
		out["chunk_frame_ms"] = stats["last_frame_ms"]
		out["chunk_worst_ms"] = stats["worst_frame_ms"]
	return out


func _table(n: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("%d fps    process %.1f ms    physics frame %.1f ms (worst %.1f)    dropped ticks %.1f/s" % [n["fps"], n["process_ms"], n["physics_ms"], n["physics_worst_ms"], n["dropped_per_second"]])
	lines.append("a tick: input+AI %.2f   simulate %.2f   record %.2f   other %.2f   = %.2f of %.1f ms (%d%%)" % [n["input_ms"], n["simulate_ms"], n["record_ms"], n["other_ms"], n["tick_ms"], n["budget_ms"], int(100.0 * n["tick_ms"] / n["budget_ms"])])
	lines.append("physics frame outside the ticks: %.1f ms (physics engine, nav, other nodes)" % n["outside_ticks_ms"])
	lines.append("pawns %d: frozen %d, dead %d" % [n["pawns"], n["frozen"], n["dead"]])
	lines.append("chunks built %d, waiting %d, to remove %d    building %.1f ms this frame, worst %.1f" % [n["chunks_built"], n["chunks_queued"], n["unloads_queued"], n["chunk_frame_ms"], n["chunk_worst_ms"]])
	return "\n".join(lines)
