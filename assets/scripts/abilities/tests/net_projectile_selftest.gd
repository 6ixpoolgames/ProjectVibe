## Written by Claude (claude-opus-5-5), 2026-11-18: projectiles over real connections, between separate Godot processes on this machine
## (net_projectile_node.gd is each machine). A server, two clients, three shooters firing bolts at the clients' strafing pawns, at three
## network conditions: clean, lag (80 ms each way with jitter) and lossy (50 ms, 5% of packets lost).
##
## What it checks, in each:
##   - Bolts are fired and hit; every bolt despawns on the server, and each client sees the server's bolts arrive and go.
##   - Hits are decided once, on the server: a client never applies one, and the server's Health is exactly 15 a hit.
##   - A client ends with the server's Health for its pawn.
##   - Hit rollback: a hit's knockback is a surprise to the client's prediction; it rolls back, and soon after each hit its pawn is
##     where the server has it again.
##
## Exits 0 on success, 1 on failure. About a minute. Add -- --only=clean|lag|lossy for one. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/abilities/tests/net_projectile_selftest.tscn"
extends SelfTest

const NODE_SCENE := "res://assets/scripts/abilities/tests/net_projectile_node.tscn"
const SECONDS := 12
const SHOOTERS := 3
const HEALTH := 1000.0
const HIT := 15.0
## Ticks after a hit by which the client's prediction must agree with the server again (the round trip plus a margin).
const SETTLE_TICKS := 40

var _port := NetRun.first_port() + 300
var _only := ""


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--only="):
			_only = argument.trim_prefix("--only=")
	print("--- Projectile network self-test ---")
	await _scenario("clean", {})
	await _scenario("lag", {"latency": 80, "jitter": 15})
	await _scenario("lossy", {"latency": 50, "loss": 0.05})
	_check(NetRun.script_errors_seen == 0, "no script errors on any machine (%d)" % NetRun.script_errors_seen)
	_finish()


func _scenario(scenario_name: String, network: Dictionary) -> void:
	if _only != "" and _only != scenario_name:
		return
	print("  [%s]" % scenario_name)
	_port += 1
	var server := {"role": "server", "seconds": SECONDS + 3, "shooters": SHOOTERS, "fire-every": 90, "fire-until": SECONDS - 1.5}
	server.merge(network)
	var machines := {"server": server}
	for label in ["one", "two"]:
		var client := {"role": "client", "seconds": SECONDS}
		client.merge(network)
		machines[label] = client
	var results := await NetRun.run(self, "projectile_" + scenario_name, machines, _port, NODE_SCENE)
	for machine_name: String in results:
		if results[machine_name].get("timed_out", false):
			_check(false, "%s: %s finished" % [scenario_name, machine_name])
			return
	var truth: Dictionary = results["server"]
	var fired: Array = truth["bolts_spawned"]
	var total_hits := 0
	for id: String in truth["hits"]:
		total_hits += int(truth["hits"][id])
	_check(int(truth["shots_started"]) == int(truth["shots_tried"]), "%s: every shot starts (%d of %d)" % [scenario_name, int(truth["shots_started"]), int(truth["shots_tried"])])
	_check(fired.size() >= 12 and total_hits > 0, "%s: bolts fly and hit (%d fired, %d hits)" % [scenario_name, fired.size(), total_hits])
	_check(int(truth["bolts_in_flight_at_end"]) <= SHOOTERS, "%s: every bolt despawns on the server (%d of %d gone, %d in flight at the end)" % [scenario_name,
		truth["bolts_despawned"].size(), fired.size(), int(truth["bolts_in_flight_at_end"])])
	var exact := true
	for id: String in truth["hits"]:
		if not is_equal_approx(float(truth["health"].get(id, -1.0)), HEALTH - HIT * int(truth["hits"][id])):
			exact = false
	_check(exact, "%s: each hit lands once on the server (Health is exactly 15 a hit)" % scenario_name)
	for label in ["one", "two"]:
		_check_client(scenario_name, label, results[label], truth)


func _check_client(scenario_name: String, label: String, client: Dictionary, truth: Dictionary) -> void:
	var tag := "%s/%s" % [scenario_name, label]
	if not client.get("joined", false):
		_check(false, "%s: joined (%s)" % [tag, client.get("refused", "")])
		return
	# Bolts: the ones the server fired before the client's last second, seen arriving and going.
	var seen := {}
	for id: Variant in client["bolts_spawned"]:
		seen[int(id)] = true
	var gone := {}
	for id: Variant in client["bolts_despawned"]:
		gone[int(id)] = true
	var server_gone := {}
	for id: Variant in truth["bolts_despawned"]:
		server_gone[int(id)] = true
	var missed := 0
	for id: Variant in truth["bolts_spawned"]:
		if server_gone.has(int(id)) and not seen.has(int(id)):
			missed += 1
	var seen_count: int = seen.size()
	_check(seen_count > 0 and missed <= SHOOTERS, "%s: it sees the server's bolts arrive (%d seen, %d of the server's finished ones missed)" % [tag, seen_count, missed])
	_check(gone.size() >= seen_count - SHOOTERS, "%s: and go (%d of %d despawned here)" % [tag, gone.size(), seen_count])
	# Hits: decided on the server only.
	var client_hits := 0
	for id: String in client["hits"]:
		client_hits += int(client["hits"][id])
	_check_equal(client_hits, 0, "%s: no hit is applied on the client" % tag)
	# Its own pawn: the server's Health, and back where the server has it soon after each hit.
	var own_id: String = client.get("own", "")
	if own_id == "":
		_check(false, "%s: has a pawn" % tag)
		return
	var server_health := float(truth["health"].get(own_id, -1.0))
	var client_health := float(client["health"].get(own_id, -2.0))
	_check(is_equal_approx(client_health, server_health) or is_equal_approx(client_health, server_health + HIT),
		"%s: its pawn's Health matches the server's (%.0f here, %.0f there)" % [tag, client_health, server_health])
	var hits_on_it: Array = truth["hit_ticks"].filter(func(entry: Array) -> bool: return str(int(entry[1])) == own_id)
	var own: Dictionary = client["positions"].get(own_id, {})
	var real: Dictionary = truth["positions"].get(own_id, {})
	# For each hit with no other hit on this pawn in the next SETTLE_TICKS: the worst misprediction while the client didn't know yet
	# (the knockback is a surprise), then the error SETTLE_TICKS after, once the rollback has corrected it.
	var hit_list: Array = hits_on_it.map(func(entry: Array) -> int: return int(entry[0]))
	var worst_after := 0.0
	var worst_during := 0.0
	var compared := 0
	for hit_tick: int in hit_list:
		if hit_list.any(func(other: int) -> bool: return other > hit_tick and other <= hit_tick + SETTLE_TICKS):
			continue
		var tick := str(hit_tick + SETTLE_TICKS)
		if not (own.has(tick) and real.has(tick)):
			continue
		worst_after = maxf(worst_after, _distance(own[tick], real[tick]))
		for step in SETTLE_TICKS:
			var during := str(hit_tick + step)
			if own.has(during) and real.has(during):
				worst_during = maxf(worst_during, _distance(own[during], real[during]))
		compared += 1
	var average := _average_error(own, real, int(client.get("measure_from_tick", 0)))
	_check(hits_on_it.is_empty() or int(client.get("rollbacks", 0)) > 0, "%s: it rolls back (%d rollbacks, %d hits on its pawn)" % [tag, int(client.get("rollbacks", 0)), hits_on_it.size()])
	_check(compared > 0 or hits_on_it.is_empty(), "%s: (%d hits apart enough to compare)" % [tag, compared])
	_check(worst_after < 0.1, "%s: %d ticks after each hit its pawn is where the server has it again (worst %.1f cm; mispredicted by up to %.0f cm before)" % [tag,
		SETTLE_TICKS, 100.0 * worst_after, 100.0 * worst_during])
	_check(average < 0.15, "%s: and it predicts well over the run (%.1f cm on average)" % [tag, 100.0 * average])


func _average_error(own: Dictionary, real: Dictionary, from_tick: int) -> float:
	var total := 0.0
	var count := 0
	for tick: String in own:
		if int(tick) >= from_tick and real.has(tick):
			total += _distance(own[tick], real[tick])
			count += 1
	return total / maxi(count, 1)


func _distance(a: Array, b: Array) -> float:
	return Vector3(a[0], a[1], a[2]).distance_to(Vector3(b[0], b[1], b[2]))
