## Written by Claude (claude-opus-5-5), 2026-11-07: chunk streaming over real connections, between separate Godot processes
## on this machine, each with its own streamer. Pawns walk nav paths on TerrainGenerator and keep crossing into new chunks.
##
## The rules being checked:
##   - The server keeps the world loaded around every player. A client only keeps it around its own pawns.
##   - Every machine builds exactly the same ground, without sending any of it.
##   - Streaming doesn't make prediction meaningfully worse than the same terrain as one fixed block.
##   - A late joiner far away, or a player leaving, works.
##   - TerrainGenerator edits reach every client and every late joiner, and all the ground still matches.
##   - Raising the ground under pawns doesn't drop them through it.
##   - AI with no source stops at the edge of the loaded ground, and comes back on when ground returns.
##   - A pawn with a source has ground on every tick, from its first one, and after being teleported somewhere new.
##
## Exits 0 on success, 1 on failure. About 2 minutes. Add -- --only=name to run one scenario. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/streaming/tests/net_streaming_selftest.tscn"
extends Node

const SECONDS := 20
const CHUNK_SIZE := 128.0
# Far enough apart that the areas each player needs can't overlap.
const FAR_APART := 1000
# Short distances, so that chunks turn over within the 20 seconds a pawn walks: about 120 m at walking speed.
const TIGHT_LOAD := 64
const TIGHT_MARGIN := 16

var _failures := 0
var _port := NetRun.first_port()
var _only := ""


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--only="):
			_only = argument.trim_prefix("--only=")
	print("--- Streaming over the network self-test ---")
	await _scenario("far_apart", _test_far_apart)
	await _scenario("against_fixed", _test_against_fixed)
	await _scenario("late_join", _test_late_join)
	await _scenario("leaving", _test_leaving)
	await _scenario("teleport", _test_teleport)
	await _scenario("ai_at_the_edge", _test_ai_at_the_edge)
	await _scenario("edits", _test_edits)
	await _scenario("raised_ground", _test_raised_ground)
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _scenario(scenario_name: String, test: Callable) -> void:
	if _only != "" and _only != scenario_name:
		return
	print("  [%s]" % scenario_name)
	_port += 1
	await test.call()


# --- Scenarios ---


func _test_far_apart() -> void:
	var results := await NetRun.run(self, "streaming_far_apart", {
		"server": _server({"spread": FAR_APART, "walkers": 2, "seconds": SECONDS + 4, "snapshot-at": SECONDS - 2, "load-distance": TIGHT_LOAD, "unload-margin": TIGHT_MARGIN}),
		"near": _client({"bench-ping": 50, "load-distance": TIGHT_LOAD, "unload-margin": TIGHT_MARGIN}),
		"far": _client({"bench-ping": 150, "load-distance": TIGHT_LOAD, "unload-margin": TIGHT_MARGIN}),
	}, _port)
	if not _all_finished(results):
		return
	var server: Dictionary = results["server"]
	var near: Dictionary = results["near"]
	var far: Dictionary = results["far"]
	_print_machine("server", server)
	_print_machine("near", near)
	_print_machine("far", far)

	# Who has what. The server's list is from just before the clients quit, because it unloads their chunks when they go.
	var snapshot: Dictionary = server.get("streaming_snapshot", {})
	var snapshot_pawns: Array = snapshot.get("pawns", [])
	_check(snapshot_pawns.size() == 4, "(the server's snapshot shows all 4 pawns: %d)" % snapshot_pawns.size())
	var all_have_ground := not snapshot_pawns.is_empty()
	for pawn: Dictionary in snapshot_pawns:
		all_have_ground = all_have_ground and pawn["has_ground"]
	_check(all_have_ground, "the server has ground under both clients' pawns at once")
	_check(_has_ground_under(near, _pawns_of(server, near)), "a client has ground under its own pawns")
	_check(_has_ground_under(far, _pawns_of(server, far)), "so does the other client")
	_check(not _has_any_ground_under(near, _pawns_of(server, far)), "a client has no ground under another player's pawns, 1 km away")
	_check(not _has_any_ground_under(far, _pawns_of(server, near)), "nor does the other client")
	var server_chunks := int(snapshot.get("chunks", 0))
	_check(server_chunks > _chunk_count(near) and server_chunks > _chunk_count(far), "the server holds more chunks than either client (%d against %d and %d)" % [server_chunks, _chunk_count(near), _chunk_count(far)])

	# Ground.
	var compared := _compare_ground(server, near) + _compare_ground(server, far)
	_check(compared > 0, "every chunk two machines share has exactly the same ground (%d compared)" % compared)
	_check(int(server["streaming"]["meshes"]) == 0 and int(server["streaming"]["collision"]) > 0, "the server built no meshes, only collision")
	_check(int(near["streaming"]["meshes"]) > 0, "clients built meshes")

	# Movement.
	for label in ["near", "far"]:
		var client: Dictionary = results[label]
		var ticks := 0
		for entity: Dictionary in NetRun.own_entities(client):
			ticks += int(NetRun.prediction_error(client, server, int(entity["id"]))["ticks"])
		_check(ticks > 1000, "%s: (compared %d ticks of its pawns against the server)" % [label, ticks])
		_check(_prediction_average(client, server) < 0.15, "%s: its own pawns stay close to the server (%.1f cm on average)" % [label, 100.0 * _prediction_average(client, server)])
		_check(_walked(server, client) > 30.0, "%s: its pawns really walked (%.0f m)" % [label, _walked(server, client)])
		_check(_most_without_ground(client) == 0, "%s: they had ground on every tick (%d without)" % [label, _most_without_ground(client)])
		var streaming: Dictionary = client["streaming"]
		_check(int(streaming["total_loaded"]) > int(client.get("chunks_at_measure_start", 0)), "%s: it kept loading chunks as they walked (%d in all, %d at the start)" % [label, int(streaming["total_loaded"]), int(client.get("chunks_at_measure_start", 0))])
		_check(int(streaming["total_unloaded"]) > 0, "%s: and unloading the ones behind (%d)" % [label, int(streaming["total_unloaded"])])
	_check(_most_without_ground(server) == 0, "server: every pawn had ground on every tick (%d without)" % _most_without_ground(server))
	_check(_nobody_fell(server), "nobody fell through the world")
	_check(int(server["stats"]["bad_packets"]) == 0, "no bad packets")


func _test_against_fixed() -> void:
	var streamed := await NetRun.run(self, "streaming_streamed", {
		"server": _server({"walkers": 2, "ai": 4, "ai-mode": "walk", "ai-loads": 1, "seconds": SECONDS + 4}),
		"a": _client({"bench-ping": 50}),
		"b": _client({"bench-ping": 100}),
	}, _port)
	_port += 1
	var fixed := await NetRun.run(self, "streaming_fixed", {
		"server": _fixed({"role": "server", "walkers": 2, "ai": 4, "ai-mode": "walk", "seconds": SECONDS + 4}),
		"a": _fixed({"role": "client", "mode": "walk", "bench-ping": 50, "seconds": SECONDS}),
		"b": _fixed({"role": "client", "mode": "walk", "bench-ping": 100, "seconds": SECONDS}),
	}, _port)
	if not _all_finished(streamed) or not _all_finished(fixed):
		return
	print("        terrain  | client | own avg/worst cm | corr/s | missed | stuck | path fails | frame avg/worst ms")
	for label in ["a", "b"]:
		_print_comparison("streamed", label, streamed)
		_print_comparison("fixed", label, fixed)
	print("        server frame avg/worst: streamed %.1f / %.0f ms, fixed %.1f / %.0f ms" % [float(streamed["server"]["loop_average_ms"]), float(streamed["server"]["loop_worst_ms"]), float(fixed["server"]["loop_average_ms"]), float(fixed["server"]["loop_worst_ms"])])

	# Two noisy numbers, so this allows for ordinary differences between runs and catches only a real change.
	for label in ["a", "b"]:
		var with_streaming := _prediction_average(streamed[label], streamed["server"])
		var without := _prediction_average(fixed[label], fixed["server"])
		_check(with_streaming <= without * 2.0 + 0.03, "%s: streaming doesn't make prediction meaningfully worse (%.1f cm against %.1f cm)" % [label, 100.0 * with_streaming, 100.0 * without])
	_check(_compare_ground(streamed["server"], streamed["a"]) > 0 and _compare_ground(streamed["server"], streamed["b"]) > 0, "streamed: the ground matches on every shared chunk")
	_check(_compare_ground(streamed["server"], fixed["server"]) > 0, "streamed and fixed terrain have the same ground")
	_check(_nobody_fell(streamed["server"]) and _nobody_fell(fixed["server"]), "nobody fell through the world in either")


func _test_late_join() -> void:
	var results := await NetRun.run(self, "streaming_late_join", {
		"server": _server({"spread": FAR_APART, "walkers": 2, "seconds": SECONDS + 4}),
		"early": _client({"bench-ping": 50}),
		"late": _client({"bench-ping": 50, "delay": 8, "seconds": SECONDS}),
	}, _port)
	if not _all_finished(results):
		return
	var server: Dictionary = results["server"]
	var late: Dictionary = results["late"]
	_check(late["joined"], "a client joins 8 seconds late")
	_check(_has_ground_under(late, _pawns_of(server, late)), "and has ground under its pawns, 1 km from the first player")
	_check(not _has_any_ground_under(late, _pawns_of(server, results["early"])), "and none under the other player's")
	_check(_most_without_ground(late) == 0, "and had ground on every tick (%d without)" % _most_without_ground(late))
	_check(_walked(server, late) > 10.0, "and walks (%.0f m)" % _walked(server, late))
	_check(_compare_ground(server, late) > 0, "and its ground matches the server's")
	_check(_nobody_fell(server), "nobody fell through the world")


func _test_leaving() -> void:
	var results := await NetRun.run(self, "streaming_leaving", {
		"server": _server({"spread": FAR_APART, "walkers": 1, "seconds": SECONDS + 4}),
		"stays": _client({"bench-ping": 50}),
		"goes": _client({"bench-ping": 50, "leave-after": 8}),
	}, _port)
	if not _all_finished(results):
		return
	var server: Dictionary = results["server"]
	# The second player's pawns started around 1 km along X, and can't have walked far in 20 seconds.
	var far_chunks := 0
	for key: String in server["streaming"]["chunks"]:
		if absf(float(key.split(",")[0]) * CHUNK_SIZE - FAR_APART) < 500.0:
			far_chunks += 1
	_check(far_chunks == 0, "when a player leaves, the server unloads the chunks around them (%d left)" % far_chunks)
	_check(_has_ground_under(server, _pawns_of(server, results["stays"])), "and keeps the other player's")
	_check(int(server["streaming"]["total_unloaded"]) > 0, "(%d chunks unloaded on the server)" % int(server["streaming"]["total_unloaded"]))
	_check(_nobody_fell(server), "nobody fell through the world")


## A respawn or a teleport: pawns land somewhere nothing is built, on every machine, with lag.
func _test_teleport() -> void:
	var results := await NetRun.run(self, "streaming_teleport", {
		"server": _server({"walkers": 2, "seconds": 16, "teleport-at": "6.5:3000"}),
		"client": _client({"bench-ping": 100, "seconds": 12}),
	}, _port)
	if not _all_finished(results):
		return
	var server: Dictionary = results["server"]
	var client: Dictionary = results["client"]
	_check(server.has("teleported"), "(the server moved the pawns 3 km)")
	_check(_most_without_ground(server) == 0, "the server had ground under them on every tick (%d without)" % _most_without_ground(server))
	_check(_most_without_ground(client) == 0, "and so did the client (%d without)" % _most_without_ground(client))
	_check(_has_ground_under(client, _pawns_of(server, client)), "and the client has ground where they ended up")
	_check(int(client["streaming"]["urgent_builds"]) > 0, "(built %d chunks immediately)" % int(client["streaming"]["urgent_builds"]))
	_check(_nobody_fell(server), "nobody fell through the world")
	_check(_walked(server, client) > 10.0, "and they kept walking (%.0f m)" % _walked(server, client))


## AI pawns with no source of their own, walking outward until they reach the edge of what the player keeps loaded.
func _test_ai_at_the_edge() -> void:
	var results := await NetRun.run(self, "streaming_ai_edge", {
		"server": _server({"walkers": 1, "ai": 8, "ai-mode": "walk", "seconds": SECONDS + 4, "load-distance": TIGHT_LOAD, "unload-margin": TIGHT_MARGIN}),
		"client": _client({"bench-ping": 50, "mode": "idle", "load-distance": TIGHT_LOAD, "unload-margin": TIGHT_MARGIN}),
	}, _port)
	if not _all_finished(results):
		return
	var server: Dictionary = results["server"]
	_check(int(server.get("ai_deactivated", 0)) > 0, "AI pawns that walk to the edge get switched off (%d times)" % int(server.get("ai_deactivated", 0)))
	_check(_most_without_ground(server) == 0, "and none ticked with no ground under it (%d without)" % _most_without_ground(server))
	_check(_nobody_fell(server), "and nobody fell through the world")
	_check(int(results["client"].get("ai_deactivated", 0)) == 0, "a client never switches anything off, because AI runs on the server")


func _test_edits() -> void:
	var results := await NetRun.run(self, "streaming_edits", {
		"server": _server({"walkers": 2, "seconds": SECONDS + 4, "edit-log": 1, "edit-every": 30, "edit-until": 840}),
		"early": _client({"bench-ping": 100, "edit-log": 1}),
		"late": _client({"bench-ping": 50, "edit-log": 1, "delay": 9, "seconds": SECONDS - 4}),
	}, _port)
	if not _all_finished(results):
		return
	var server: Dictionary = results["server"]
	var expected := int(server["streaming"].get("edits_in_log", 0))
	_check(expected >= 15, "(the server made %d edits)" % expected)
	for label in ["early", "late"]:
		var client: Dictionary = results[label]
		_check(int(client["streaming"].get("edits_in_log", 0)) == expected, "%s: its log has them all (%d)" % [label, int(client["streaming"].get("edits_in_log", 0))])
		var compared := _compare_ground(server, client)
		_check(compared > 0, "%s: and every chunk it shares with the server has exactly the same ground (%d compared)" % [label, compared])
	_check(_compare_ground(results["early"], results["late"]) > 0, "and the two clients match each other")
	_check(int(server["stats"]["bad_packets"]) == 0, "no bad packets")
	_check(_nobody_fell(server), "nobody fell through the world")


## The bug in the netcode spec's to-do 17: ground rising above a pawn left it under a one-sided surface.
func _test_raised_ground() -> void:
	var results := await NetRun.run(self, "streaming_raised", {
		"server": _server({"walkers": 4, "ai": 8, "ai-loads": 1, "seconds": SECONDS + 4, "edit-log": 1, "edit-every": 20, "edit-raise": 1, "edit-until": 900}),
		"client": _client({"bench-ping": 50, "mode": "idle", "edit-log": 1}),
	}, _port)
	if not _all_finished(results):
		return
	var server: Dictionary = results["server"]
	var highest := -INF
	for entity: Dictionary in server["summaries"]:
		highest = maxf(highest, float(entity["y"]))
	_check(int(server["streaming"].get("edits_in_log", 0)) >= 20, "(the server raised the ground %d times around the pawns, and the highest pawn is at %.0f m)" % [int(server["streaming"].get("edits_in_log", 0)), highest])
	_check(_nobody_fell(server), "nobody fell through the raised ground")
	var client: Dictionary = results["client"]
	for entity: Dictionary in client["summaries"]:
		if float(entity["y"]) < -30.0:
			_check(false, "a pawn fell on the client")
			return
	_check(true, "nor on the client")


# --- Machines ---


func _server(extra: Dictionary) -> Dictionary:
	var settings := {"role": "server", "terrain": 1, "streaming": 1}
	settings.merge(extra, true) # true: what a scenario asks for wins
	return settings


func _client(extra: Dictionary) -> Dictionary:
	var settings := {"role": "client", "terrain": 1, "streaming": 1, "mode": "walk", "seconds": SECONDS}
	settings.merge(extra, true) # true: what a scenario asks for wins
	return settings


func _fixed(extra: Dictionary) -> Dictionary:
	var settings := {"terrain": 1, "fixed-block": 1}
	settings.merge(extra, true) # true: what a scenario asks for wins
	return settings


# --- Reading results ---


func _all_finished(results: Dictionary) -> bool:
	var finished := true
	for label: String in results:
		if results[label].has("timed_out") or not results[label].has("summaries"):
			_check(false, "%s finished" % label)
			finished = false
	return finished


## The positions, on the server, of the pawns this client owns.
func _pawns_of(server: Dictionary, client: Dictionary) -> Array:
	var pawns := []
	for entity: Dictionary in NetRun.own_entities(client):
		var on_server := NetRun.summary_of(server, int(entity["id"]))
		if not on_server.is_empty():
			pawns.append(on_server)
	return pawns


func _chunk_name(pawn: Dictionary) -> String:
	return "%d,%d" % [floori(float(pawn["x"]) / CHUNK_SIZE), floori(float(pawn["z"]) / CHUNK_SIZE)]


func _has_ground_under(machine: Dictionary, pawns: Array) -> bool:
	if pawns.is_empty():
		return false
	for pawn: Dictionary in pawns:
		if not machine["streaming"]["chunks"].has(_chunk_name(pawn)):
			return false
	return true


func _has_any_ground_under(machine: Dictionary, pawns: Array) -> bool:
	for pawn: Dictionary in pawns:
		if machine["streaming"]["chunks"].has(_chunk_name(pawn)):
			return true
	return false


func _chunk_count(machine: Dictionary) -> int:
	return machine["streaming"]["chunks"].size()


## Checks every chunk both machines have, and returns how many. One that differs is a failure. Returns 0 if any differ.
func _compare_ground(a: Dictionary, b: Dictionary) -> int:
	var a_chunks: Dictionary = a["streaming"]["chunks"]
	var b_chunks: Dictionary = b["streaming"]["chunks"]
	var compared := 0
	for key: String in a_chunks:
		if b_chunks.has(key):
			if a_chunks[key] != b_chunks[key]:
				print("        chunk %s differs" % key)
				return 0
			compared += 1
	return compared


func _prediction_average(client: Dictionary, server: Dictionary) -> float:
	var owned := NetRun.own_entities(client)
	var total := 0.0
	for entity: Dictionary in owned:
		total += NetRun.prediction_error(client, server, int(entity["id"]))["average"]
	return total / maxi(owned.size(), 1)


func _prediction_worst(client: Dictionary, server: Dictionary) -> float:
	var worst := 0.0
	for entity: Dictionary in NetRun.own_entities(client):
		worst = maxf(worst, NetRun.prediction_error(client, server, int(entity["id"]))["worst"])
	return worst


## The shortest distance any of this client's pawns walked, as the client counted it.
func _walked(_server_results: Dictionary, client: Dictionary) -> float:
	var shortest := INF
	for entity: Dictionary in NetRun.own_entities(client):
		shortest = minf(shortest, float(entity.get("walked", 0.0)))
	return 0.0 if shortest == INF else shortest


func _most_without_ground(machine: Dictionary) -> int:
	var most := 0
	for entity: Dictionary in machine.get("summaries", []):
		var ticks: Variant = entity.get("no_ground", 0)
		if ticks != null:
			most = maxi(most, int(ticks))
	return most


func _nobody_fell(server: Dictionary) -> bool:
	for entity: Dictionary in server.get("summaries", []):
		if float(entity.get("y", 0.0)) < -30.0:
			return false
	return true


func _print_machine(label: String, machine: Dictionary) -> void:
	var numbers: Dictionary = machine["streaming"]
	print("        %s: %d chunks now, %d loaded, %d unloaded, %d meshes, streamer worst frame %.2f ms, worst step %.2f ms, game frame avg %.1f / worst %.0f ms" % [
		label, numbers["chunks"].size(), int(numbers["total_loaded"]), int(numbers["total_unloaded"]), int(numbers["meshes"]),
		float(numbers["worst_frame_ms"]), float(numbers["worst_step_ms"]), float(machine["loop_average_ms"]), float(machine["loop_worst_ms"]),
	])


func _print_comparison(terrain: String, label: String, results: Dictionary) -> void:
	var client: Dictionary = results[label]
	var server: Dictionary = results["server"]
	var stats: Dictionary = client["stats"]
	var pawns := maxi(NetRun.own_entities(client).size(), 1)
	var seconds: float = maxf((float(client["measure_end_usec"]) - float(client["measure_start_usec"])) / 1000000.0, 0.001)
	var stuck := 0
	var path_failures := 0
	for entity: Dictionary in NetRun.own_entities(client):
		stuck += int(entity.get("stuck", 0))
		path_failures += int(entity.get("path_failures", 0))
	print("        %-8s | %-6s | %.1f / %.0f | %.2f | %d | %d | %d | %.1f / %.0f" % [
		terrain, label, 100.0 * _prediction_average(client, server), 100.0 * _prediction_worst(client, server),
		(float(stats["corrections"]) - float(client.get("corrections_start", 0))) / (pawns * seconds),
		int(client["missed_inputs"]) - int(client.get("missed_inputs_start", 0)), stuck, path_failures,
		float(client["loop_average_ms"]), float(client["loop_worst_ms"]),
	])


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
