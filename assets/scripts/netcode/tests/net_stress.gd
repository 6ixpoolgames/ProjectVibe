## Written by Claude (claude-opus-5-5), 2026-11-05: many networked pawns walking nav paths over hills, at different pings.
## Each client is its own Godot process with its own ping and 4 pawns, and the server adds 20 AI pawns of its own. First everyone
## stays within what the netcode is designed for, then one or two clients go out of bounds, then machines hitch. Prints a table;
## it doesn't pass or fail. Takes several minutes.
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/netcode/tests/net_stress.tscn"
## Add -- --row=name to run one row.
## Claude 2026-11-09 (scaling spec section 0): -- --stretch=1.6 makes the server act like the target machine's slower CPU (its main
## thread only), and -- --workers=3 gives it the target machine's 3 job worker threads.
##
## The question to read it with: when someone else has a bad connection, do the good clients' numbers change? In a
## server-authoritative design they shouldn't, apart from that one pawn looking bad to everyone.
##
## The columns, per client:
##   own avg/worst       its own pawns against the server on the same tick, as first predicted
##   alone avg/worst     the same, only on ticks with no other pawn within 2 m, so slopes and nav without pawn contact
##   corr/s, jump/s      corrections per second per pawn, and how far they moved pawns per second per pawn
##   missed              inputs the server had to do without
##   gap                 the longest run of those for one pawn, in ticks, leaving out before its first input and after its last
##   view, behind        remote pawns against where they really were, and how many ticks behind they're drawn
##   late                ticks with no snapshot to draw from
##   stuck               times a pawn gave up on a path
##   down/up             kilobytes per second
##   frame avg/worst     milliseconds of tick work per frame. Over budget is frames taking more than 16.7 ms
##
## All of this runs on one computer, so machines compete for CPU and some hitches are the computer's. That's still informative.
extends Node

const SECONDS := 30
const WALKERS := 4
const AI_PAWNS := 20
const GOOD := [{"name": "ping20", "bench-ping": 20}, {"name": "ping50", "bench-ping": 50}, {"name": "ping100", "bench-ping": 100}, {"name": "ping150", "bench-ping": 150}, {"name": "ping200", "bench-ping": 200}]

# Claude 2026-11-07: the default streaming distances, with the nav distance the stress test for streaming uses.
const FIXED_BLOCK := {"fixed-block": 1, "nav-distance": 96}
const REAL_PAWN := {"streaming": 1, "real-pawn": 1, "load-distance": 320, "nav-distance": 96, "unload-margin": 64}
const STREAMED := {"streaming": 1, "load-distance": 320, "nav-distance": 96, "unload-margin": 64}

var _port := NetRun.first_port()
var _only := ""
var _server_extra := {} # Claude 2026-11-09: --stretch and --workers, for the server


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--row="):
			_only = argument.trim_prefix("--row=")
		elif argument.begins_with("--stretch="): # Claude 2026-11-09
			_server_extra["stretch"] = float(argument.trim_prefix("--stretch="))
		elif argument.begins_with("--workers="):
			_server_extra["workers"] = int(argument.trim_prefix("--workers="))
	print("--- Multiplayer stress test (physics engine: %s), %d walkers per client plus %d AI, %d s ---" % [ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"), WALKERS, AI_PAWNS, SECONDS])
	await _row("within_limits", GOOD, {})
	await _row("one_bad", GOOD + [{"name": "ping400", "bench-ping": 400}], {})
	await _row("two_bad", GOOD + [{"name": "ping400", "bench-ping": 400}, {"name": "worst", "preset": "worst", "conditions-seed": 41}], {})
	await _row("client_hitches", [GOOD[0], GOOD[1], GOOD[2], GOOD[3], {"name": "ping100_hitch", "bench-ping": 100, "hitch": "4:250"}], {})
	await _row("server_hitches", GOOD, {"hitch": "4:150"})
	# Claude 2026-11-07: the same crowd on TerrainGenerator, first as one fixed block and then loaded around each player.
	await _row("terrain_fixed", _with(GOOD, FIXED_BLOCK), FIXED_BLOCK)
	await _row("terrain_streamed", _with(GOOD, STREAMED), _merged(STREAMED, {"ai-loads": 1}))
	# Claude 2026-11-07: the same again with the real motor and cameras: each client possesses one of its pawns.
	await _row("pawn_streamed", _with(GOOD, REAL_PAWN), _merged(REAL_PAWN, {"ai-loads": 1, "possess": 1}))
	print("--- DONE ---")
	get_tree().quit(0)


## Claude 2026-11-07: a copy of each client's settings, plus these.
func _with(clients: Array, extra: Dictionary) -> Array:
	var copies := []
	for client: Dictionary in clients:
		copies.append(_merged(client, extra))
	return copies


func _merged(a: Dictionary, b: Dictionary) -> Dictionary:
	var merged := a.duplicate()
	merged.merge(b)
	return merged


func _row(row_name: String, clients: Array, server_extra: Dictionary) -> void:
	if _only != "" and _only != row_name:
		return
	_port += 1
	var machines: Dictionary = {}
	# Clients start a moment apart, so the server has to outlast the last of them.
	var server: Dictionary = {"role": "server", "seconds": SECONDS + 4, "terrain": 1, "walkers": WALKERS, "ai": AI_PAWNS, "ai-mode": "walk"}
	server.merge(server_extra)
	server.merge(_server_extra) # Claude 2026-11-09
	machines["server"] = server
	for client: Dictionary in clients:
		var settings: Dictionary = {"role": "client", "seconds": SECONDS, "terrain": 1, "mode": "walk"}
		settings.merge(client)
		settings.erase("name")
		machines[client["name"]] = settings
	var results := await NetRun.run(self, "stress_%s" % row_name, machines, _port)
	print("")
	print("[%s]" % row_name)
	if results["server"].has("timed_out"):
		print("the server didn't finish")
		return
	print("client | own avg/worst cm | alone avg/worst cm | corr/s | jump/s cm | missed | gap | resyncs | view cm | behind | late | stuck | down/up KB/s | frame avg/worst ms | over budget")
	for client: Dictionary in clients:
		_print_client(client["name"], results[client["name"]], results["server"])
	_print_server(results["server"])


func _print_client(label: String, client: Dictionary, server: Dictionary) -> void:
	if client.has("timed_out") or not client.has("summaries"):
		print("%s | didn't finish" % label)
		return
	var owned := NetRun.own_entities(client)
	var own_total := 0.0
	var own_worst := 0.0
	var alone := {"total": 0.0, "worst": 0.0, "ticks": 0}
	var stuck := 0
	for entity: Dictionary in owned:
		var id := int(entity["id"])
		var error := NetRun.prediction_error(client, server, id)
		own_total += error["average"]
		own_worst = maxf(own_worst, error["worst"])
		stuck += int(entity.get("stuck", 0))
		_add_alone_error(alone, client, server, id)
	var pawns := maxi(owned.size(), 1)
	var seconds: float = maxf((float(client["measure_end_usec"]) - float(client["measure_start_usec"])) / 1000000.0, 0.001)
	var stats: Dictionary = client["stats"]
	var corrections: float = float(stats["corrections"]) - float(client.get("corrections_start", 0))
	var jump: float = float(stats["jump_total"]) - float(client.get("jump_total_start", 0))
	var view := _remote_view(client, server, owned)
	var band := NetRun.bandwidth(client)
	print("%s | %.1f / %.0f | %.2f / %.0f | %.2f | %.0f | %d | %d | %d | %.1f | %.1f | %d | %d | %.1f / %.1f | %.1f / %.0f | %d of %d" % [
		label, 100.0 * own_total / pawns, 100.0 * own_worst,
		100.0 * float(alone["total"]) / maxi(int(alone["ticks"]), 1), 100.0 * float(alone["worst"]),
		corrections / (pawns * seconds), 100.0 * jump / (pawns * seconds),
		int(client["missed_inputs"]) - int(client.get("missed_inputs_start", 0)),
		_longest_gap(server, owned),
		int(stats["resyncs"]) - int(client.get("resyncs_start", 0)),
		100.0 * float(view["average"]), float(view["behind"]),
		int(stats["interpolation_underruns"]) - int(client.get("interpolation_underruns_start", 0)), stuck,
		band["received"] / 1000.0, band["sent"] / 1000.0,
		float(client["loop_average_ms"]), float(client["loop_worst_ms"]), int(client["loops_over_budget"]), int(client["loop_count"]),
	])
	if client.has("possession"):
		var info: Dictionary = client["possession"]
		print("    camera: on pawn %d, %.3f m a frame on average, worst %.2f m" % [int(info["my_pawn"]), float(info["camera_average_jump"]), float(info["camera_worst_jump"])])


## The longest stretch of missing input for any of these pawns, once it had started sending and before it stopped.
func _longest_gap(server: Dictionary, owned: Array) -> int:
	var longest := 0
	for entity: Dictionary in owned:
		var on_server := NetRun.summary_of(server, int(entity["id"]))
		var stretches: Array = on_server.get("missing_stretches", [])
		var last_input := int(on_server.get("last_input_tick", -1))
		for i in stretches.size():
			var stretch: Array = stretches[i]
			if i == 0 or int(stretch[0]) > last_input:
				continue
			longest = maxi(longest, int(stretch[1]) - int(stretch[0]) + 1)
	return longest


func _print_server(server: Dictionary) -> void:
	var band := NetRun.bandwidth(server)
	var stuck := 0
	var failures := 0
	var walked := 0.0
	var fell := 0
	for entity: Dictionary in server.get("summaries", []):
		if float(entity.get("y", 0.0)) < -30.0:
			fell += 1
		if int(entity.get("owner", -1)) == 0:
			stuck += int(entity.get("stuck", 0))
			failures += int(entity.get("path_failures", 0))
			walked += float(entity.get("walked", 0.0))
	print("server: sends %.1f KB/s in total, frame avg %.1f ms, worst %.0f ms, %d of %d frames over budget, %d ticks dropped, %d hitches, AI walked %.0f m, stuck %d, %d path failures, %d bad packets, %d pawns fell through the world" % [
		band["sent"] / 1000.0, float(server["loop_average_ms"]), float(server["loop_worst_ms"]), int(server["loops_over_budget"]), int(server["loop_count"]), int(server["dropped_ticks"]), int(server["hitches"]), walked, stuck, failures, int(server["stats"]["bad_packets"]), fell,
	])


## The own-pawn error, only on ticks with no other pawn within 2 m of it on the server.
func _add_alone_error(totals: Dictionary, client: Dictionary, server: Dictionary, entity_id: int) -> void:
	var own: Dictionary = client["positions"].get(str(entity_id), {})
	var all_truth: Dictionary = server["positions"]
	var truth: Dictionary = all_truth.get(str(entity_id), {})
	var from_tick := int(client.get("measure_from_tick", 0))
	for tick_text: String in own:
		if int(tick_text) < from_tick or not truth.has(tick_text):
			continue
		var here: Array = truth[tick_text]
		var near := false
		for other_id: String in all_truth:
			if other_id == str(entity_id) or not all_truth[other_id].has(tick_text):
				continue
			var there: Array = all_truth[other_id][tick_text]
			if absf(float(here[0]) - float(there[0])) < 2.0 and absf(float(here[2]) - float(there[2])) < 2.0:
				near = true
				break
		if near:
			continue
		var mine: Array = own[tick_text]
		var error := Vector3(float(mine[0]) - float(here[0]), float(mine[1]) - float(here[1]), float(mine[2]) - float(here[2])).length()
		totals["total"] = float(totals["total"]) + error
		totals["worst"] = maxf(float(totals["worst"]), error)
		totals["ticks"] = int(totals["ticks"]) + 1


## How remote pawns look on this client, averaged over all of them.
func _remote_view(client: Dictionary, server: Dictionary, owned: Array) -> Dictionary:
	var own_ids: Array = owned.map(func(e: Dictionary) -> int: return int(e["id"]))
	var total := 0.0
	var behind := 0.0
	var count := 0
	for id_text: String in client.get("views", {}):
		if own_ids.has(int(id_text)):
			continue
		var view := NetRun.view_error(client, server, int(id_text))
		if int(view["ticks"]) > 0:
			total += view["average"]
			behind += view["behind_ticks"]
			count += 1
	return {"average": total / maxi(count, 1), "behind": behind / maxi(count, 1)}
