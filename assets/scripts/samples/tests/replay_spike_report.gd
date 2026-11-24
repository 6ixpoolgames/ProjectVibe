# Written by Claude (claude-opus-5-5), 2026-11-24: lists the spikes in a replay's diagnostics channel, with the spawns in each
# spiking frame, and compares the physics time of frames with and without a spawn. A measuring tool, not a test.
#   godot --headless --path . "res://assets/scripts/samples/tests/replay_spike_report.tscn" -- <replay file> [threshold ms]
extends Node


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var path: String = args[0]
	var threshold := float(args[1]) if args.size() > 1 else 40.0
	var reader := ReplayReader.new()
	if reader.open(path) != OK:
		print("can't open ", path)
		get_tree().quit(1)
		return
	var first := reader.get_first_tick()
	var last := reader.get_last_tick()
	var spawns_at := {}
	var spawn_total := 0
	for event: Dictionary in reader.get_events(first, last):
		if event.channel == "spawns" and String(event.kind) == "spawned":
			spawns_at[event.tick] = spawns_at.get(event.tick, 0) + 1
			spawn_total += 1
	var frames := reader.get_diagnostics(first, last)
	print("ticks %d..%d (%.0f s), %d frames, %d spawns" % [first, last, (last - first) / 60.0, frames.size(), spawn_total])
	var spiky := 0
	var with_spawn := 0
	var spawn_frames := 0
	var spawn_frame_ms := 0.0
	var plain_frame_ms := 0.0
	var plain_frames := 0
	var by_kind := {"rest": 0, "physics": 0, "other": 0}
	for pair: Array in frames:
		var tick: int = pair[0]
		var f: Dictionary = pair[1]
		var near := 0
		for t in range(tick - f.steps, tick + 1):
			near += spawns_at.get(t, 0)
		if near > 0:
			spawn_frames += 1
			spawn_frame_ms += f.physics_ms
		elif (tick - first) > 600:
			plain_frames += 1
			plain_frame_ms += f.physics_ms
		if f.frame_ms < threshold or (tick - first) < 120:
			continue
		spiky += 1
		if near > 0:
			with_spawn += 1
		var kind := "rest" if f.rest_ms > f.physics_ms else "physics"
		by_kind[kind] += 1
		var top: Array = []
		for name: String in f.scopes:
			top.append([f.scopes[name][0] / 1000.0, name])
		top.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
		var parts := PackedStringArray()
		for i in mini(4, top.size()):
			parts.append("%s %.1f" % [top[i][1], top[i][0]])
		print("%7.1fs %6.1f ms = physics %5.1f (%d steps) + scripts %4.1f + rest %5.1f | spawns this frame %d | %s" % [(tick - first) / 60.0, f.frame_ms, f.physics_ms, f.steps, f.scripts_ms, f.rest_ms, near, ", ".join(parts)])
	print("spikes over %.0f ms after the first 2 s: %d (%d mostly physics, %d mostly rest), %d with a spawn in the frame" % [threshold, spiky, by_kind.physics, by_kind.rest, with_spawn])
	print("physics ms a frame: %.1f in frames with a spawn (%d frames), %.1f in frames without (after 10 s, %d frames)" % [spawn_frame_ms / maxf(spawn_frames, 1), spawn_frames, plain_frame_ms / maxf(plain_frames, 1), plain_frames])
	get_tree().quit(0)
