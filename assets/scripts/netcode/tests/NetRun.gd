## Written by Claude (claude-opus-5-5), 2026-11-04: starts a group of test machines as separate Godot processes and collects
## what each one wrote. Shared by net_selftest.gd and net_measure.gd.
class_name NetRun
extends RefCounted

const NODE_SCENE := "res://assets/scripts/netcode/tests/net_test_node.tscn"
## Extra time for processes to start and finish, on top of how long the longest machine plays.
const EXTRA_SECONDS := 15.0


## Starts every machine in machines ({name: {setting: value}}), waits for them all to finish, and returns {name: result}.
## A machine that didn't finish in time is stopped, and has "timed_out" in its result. owner is any node in the tree.
static func run(owner: Node, run_name: String, machines: Dictionary, port: int) -> Dictionary:
	var folder := ProjectSettings.globalize_path("user://net_test/%s" % run_name)
	DirAccess.make_dir_recursive_absolute(folder)
	var pids: Dictionary = {}
	var outs: Dictionary = {}
	var longest := 0.0
	for machine_name: String in machines:
		var settings: Dictionary = machines[machine_name]
		var out_path := "%s/%s.json" % [folder, machine_name]
		DirAccess.remove_absolute(out_path)
		outs[machine_name] = out_path
		var arguments := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), NODE_SCENE, "--"])
		arguments.append("--name=%s" % machine_name)
		arguments.append("--port=%d" % port)
		arguments.append("--out=%s" % out_path)
		for key: String in settings:
			arguments.append("--%s=%s" % [key, str(settings[key])])
		longest = maxf(longest, float(settings.get("seconds", 8)) + float(settings.get("delay", 0)))
		pids[machine_name] = OS.create_process(OS.get_executable_path(), arguments, false)
		# The server has to be listening before anyone joins.
		await owner.get_tree().create_timer(0.3).timeout
	var deadline := Time.get_ticks_msec() + int((longest + EXTRA_SECONDS) * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var all_done := true
		for machine_name: String in pids:
			if OS.is_process_running(pids[machine_name]):
				all_done = false
		if all_done:
			break
		await owner.get_tree().create_timer(0.1).timeout
	var results: Dictionary = {}
	for machine_name: String in pids:
		if OS.is_process_running(pids[machine_name]):
			OS.kill(pids[machine_name])
			results[machine_name] = {"timed_out": true}
			continue
		var file := FileAccess.open(outs[machine_name], FileAccess.READ)
		if file == null:
			results[machine_name] = {"timed_out": true, "no_output": true}
			continue
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		results[machine_name] = parsed if parsed is Dictionary else {"timed_out": true, "bad_output": true}
	return results


## How far a predicted pawn was from the server on each tick, as first predicted, in metres. The result is
## {"average": m, "worst": m, "ticks": n}. entity_id is the pawn, client and server are results from run().
static func prediction_error(client: Dictionary, server: Dictionary, entity_id: int) -> Dictionary:
	var own: Dictionary = client.get("positions", {}).get(str(entity_id), {})
	var truth: Dictionary = server.get("positions", {}).get(str(entity_id), {})
	var from_tick: int = int(client.get("measure_from_tick", 0))
	var total := 0.0
	var worst := 0.0
	var count := 0
	for tick_text: String in own:
		if int(tick_text) < from_tick or not truth.has(tick_text):
			continue
		var error := _distance(own[tick_text], truth[tick_text])
		total += error
		worst = maxf(worst, error)
		count += 1
	return {"average": total / maxi(count, 1), "worst": worst, "ticks": count}


## How far a remote pawn as drawn was from the server's position at the moment being drawn, in metres. Near zero means the
## interpolation matches what really happened. Also gives how far behind the client's own tick it was drawn, in ticks.
static func view_error(client: Dictionary, server: Dictionary, entity_id: int) -> Dictionary:
	var views: Dictionary = client.get("views", {}).get(str(entity_id), {})
	var truth: Dictionary = server.get("positions", {}).get(str(entity_id), {})
	var from_tick: int = int(client.get("measure_from_tick", 0))
	var total := 0.0
	var worst := 0.0
	var behind_total := 0.0
	var step_worst := 0.0
	var count := 0
	var previous: Variant = null
	for tick_text: String in views:
		if int(tick_text) < from_tick:
			continue
		var view: Array = views[tick_text]
		var render := float(view[0])
		behind_total += int(tick_text) - render
		var before_text := str(floori(render))
		var after_text := str(floori(render) + 1)
		if truth.has(before_text) and truth.has(after_text):
			var a: Array = truth[before_text]
			var b: Array = truth[after_text]
			var weight := render - floori(render)
			var at_render := [lerpf(a[0], b[0], weight), lerpf(a[1], b[1], weight), lerpf(a[2], b[2], weight)]
			var error := _distance([view[1], view[2], view[3]], at_render)
			total += error
			worst = maxf(worst, error)
			count += 1
		if previous != null:
			step_worst = maxf(step_worst, _distance([view[1], view[2], view[3]], previous))
		previous = [view[1], view[2], view[3]]
	return {"average": total / maxi(count, 1), "worst": worst, "ticks": count, "behind_ticks": behind_total / maxi(count, 1), "largest_step": step_worst}


## Bytes per second this machine sent and received while measuring.
static func bandwidth(machine: Dictionary) -> Dictionary:
	var stats: Dictionary = machine.get("stats", {})
	var seconds: float = (float(machine.get("measure_end_usec", 0)) - float(machine.get("measure_start_usec", 0))) / 1000000.0
	if seconds <= 0.0:
		return {"sent": 0.0, "received": 0.0}
	return {
		"sent": (float(stats.get("bytes_sent", 0)) - float(machine.get("bytes_sent_start", 0))) / seconds,
		"received": (float(stats.get("bytes_received", 0)) - float(machine.get("bytes_received_start", 0))) / seconds,
	}


## The entity a client owns, from its summary.
static func own_entity(client: Dictionary) -> Dictionary:
	for entity: Dictionary in client.get("summaries", []):
		if int(entity.get("owner", -1)) == int(client.get("peer", -2)):
			return entity
	return {}


## What a machine last knew about an entity, even if it's gone by the end. Clients quit before the server does.
static func summary_of(machine: Dictionary, entity_id: int) -> Dictionary:
	for entity: Dictionary in machine.get("summaries", []):
		if int(entity.get("id", -1)) == entity_id:
			return entity
	return {}


static func _distance(a: Array, b: Array) -> float:
	return Vector3(float(a[0]), float(a[1]), float(a[2])).distance_to(Vector3(float(b[0]), float(b[1]), float(b[2])))
