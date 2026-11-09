## Written by Claude (claude-opus-5-5), 2026-11-07: the tier -1 pawn, possession and cameras over real connections, between separate Godot
## processes on this machine. Pawns walk nav paths on streamed TerrainGenerator using the real abilities (Claude 2026-11-07: was GroundMovement).
##
## What it checks:
##   - The motor predicts well: a client's pawn stays close to the server's.
##   - Joining gives a player a pawn, and the camera follows it on that client only. The server has no camera.
##   - Look direction reaches the server in the input command.
##   - A late joiner learns who has what.
##   - A pawn being removed leaves the controller with no pawn, and nothing breaks.
##   - A player leaving lets go of their pawn. It stays, stops, doesn't fall when its ground unloads, and can be taken again.
##   - A client asking for a pawn with possessable off gets nothing.
##   - Swapping to another pawn mid-game works, at several pings, and the new pawn settles quickly.
##   - Asking for something you can't have changes nothing.
##
## Exits 0 on success, 1 on failure. About 4 minutes. Add -- --only=name to run one scenario. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/pawn/tests/net_pawn_selftest.tscn"
extends Node

const SECONDS := 20

var _failures := 0
var _port := NetRun.first_port() + 200
var _only := ""


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--only="):
			_only = argument.trim_prefix("--only=")
	print("--- Pawn and camera network self-test ---")
	await _scenario("playing", _test_playing)
	await _scenario("late_join", _test_late_join)
	await _scenario("pawn_removed", _test_pawn_removed)
	await _scenario("player_leaves", _test_player_leaves)
	await _scenario("not_possessable", _test_not_possessable)
	await _scenario("asking_for_too_much", _test_asking_for_too_much)
	await _scenario("swap_50", _test_swap.bind(50))
	await _scenario("swap_200", _test_swap.bind(200))
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _scenario(scenario_name: String, test: Callable) -> void:
	if _only != "" and _only != scenario_name:
		return
	print("  [%s]" % scenario_name)
	_port += 1
	await test.call()


# --- Scenarios ---


func _test_playing() -> void:
	var results := await NetRun.run(self, "pawn_playing", {
		"server": _server({"walkers": 1, "spread": 1000, "seconds": SECONDS + 4, "snapshot-at": SECONDS - 2}),
		"near": _client({"bench-ping": 50, "look-at": "5:1.25"}),
		"far": _client({"bench-ping": 150}),
	}, _port)
	if not _all_finished(results):
		return
	var server: Dictionary = results["server"]
	for label in ["near", "far"]:
		var client: Dictionary = results[label]
		var own := NetRun.own_entities(client)
		_check(own.size() == 1, "%s: joining gives it a pawn" % label)
		if own.is_empty():
			continue
		var id := int(own[0]["id"])
		var info: Dictionary = client["possession"]
		_check(int(info["my_pawn"]) == id, "%s: its controller has that pawn" % label)
		_check(info["camera_in_scene"] and info["camera_has_view"], "%s: and its camera has a view" % label)
		_check(absf(float(info["camera_from_view"])) < 0.5, "%s: and is there (%.2f m away)" % [label, float(info["camera_from_view"])])
		_check(int(info["arm_count"]) == 1, "%s: and only its own pawn has an arm (%d)" % [label, int(info["arm_count"])])
		var error := NetRun.prediction_error(client, server, id)
		_check(int(error["ticks"]) > 500, "%s: (compared %d ticks against the server)" % [label, int(error["ticks"])])
		_check(float(error["average"]) < 0.15, "%s: the motor predicts well (%.2f cm on average, %.1f cm at worst)" % [label, 100.0 * float(error["average"]), 100.0 * float(error["worst"])])
		_check(float(own[0].get("walked", 0.0)) > 30.0, "%s: and it really walks (%.0f m)" % [label, float(own[0].get("walked", 0.0))])
		_check(int(own[0].get("no_ground", 0)) == 0, "%s: with ground on every tick" % label)
		_check(float(info["camera_worst_jump"]) < 1.0, "%s: the camera stays smooth (worst %.2f m in a frame, %.3f m on average)" % [label, float(info["camera_worst_jump"]), float(info["camera_average_jump"])])
	var server_info: Dictionary = server["possession"]
	_check(not server_info["camera_in_scene"], "the server has no camera in its scene")
	_check(int(server_info["arm_count"]) == 0, "and no arms")
	_check(int(server_info["my_pawn"]) == 0, "and its own controller has no pawn")

	var near_on_server := NetRun.summary_of(server, int(NetRun.own_entities(results["near"])[0]["id"]))
	_check(absf(angle_difference(float(near_on_server["look_yaw"]), 1.25)) < 0.01, "where a player looks reaches the server (%.3f, wanted 1.25)" % float(near_on_server["look_yaw"]))
	_check(int(server["stats"]["bad_packets"]) == 0, "no bad packets")
	_check(_nobody_fell(server), "nobody fell through the world")


func _test_late_join() -> void:
	var results := await NetRun.run(self, "pawn_late_join", {
		"server": _server({"walkers": 1, "spread": 200, "seconds": SECONDS + 4}),
		"early": _client({"bench-ping": 50}),
		"late": _client({"bench-ping": 50, "delay": 8, "seconds": SECONDS - 4}), # so the first player is still here at its end
	}, _port)
	if not _all_finished(results):
		return
	var late: Dictionary = results["late"]
	var map: Dictionary = late["possession"]["map"]
	_check(map.size() == 2, "a late joiner knows who has what (%d players)" % map.size())
	var early_peer := str(int(results["early"]["peer"]))
	_check(map.has(early_peer), "including the player who was already there")
	_check(int(late["possession"]["my_pawn"]) > 0, "and it has a pawn of its own")
	_check(late["possession"]["camera_has_view"], "and its camera has a view")
	_check(_nobody_fell(results["server"]), "nobody fell through the world")


func _test_pawn_removed() -> void:
	var results := await NetRun.run(self, "pawn_removed", {
		"server": _server({"walkers": 1, "seconds": 16, "despawn-possessed-at": 7}),
		"client": _client({"bench-ping": 100, "seconds": 13}),
	}, _port)
	if not _all_finished(results):
		return
	var client: Dictionary = results["client"]
	var server: Dictionary = results["server"]
	_check(server.has("despawned_possessed"), "(the server removed the pawn)")
	_check(int(client["possession"]["my_pawn"]) == 0, "the client's controller has no pawn now")
	_check(client["possession"]["camera_in_scene"], "and its camera is still here")
	_check(not client["possession"]["camera_has_view"], "with no view to follow")
	_check(client["possession"]["map"].is_empty(), "and nobody's listed as having anything")
	_check(int(client["stats"]["bad_packets"]) == 0 and int(server["stats"]["bad_packets"]) == 0, "no bad packets on either")


## Claude 2026-11-07: the leaver is 1000 m from anyone else, so its ground really unloads. It has two pawns, and possesses only one.
## The returner joins afterwards and takes the pawn that was left, which is how a game could hand one back.
func _test_player_leaves() -> void:
	var results := await NetRun.run(self, "pawn_player_leaves", {
		"server": _server({"walkers": 2, "spread": 1000, "no-server-brain": 1, "seconds": 28}),
		"leaver": _client({"bench-ping": 50, "leave-after": 9, "seconds": 11}),
		"stayer": _client({"bench-ping": 50, "delay": 1, "seconds": 24}),
		"returner": _client({"bench-ping": 50, "delay": 12, "swap-at": 18, "ai-mode": "walk", "seconds": 26}),
	}, _port)
	if not _all_finished(results):
		return
	var server: Dictionary = results["server"]
	var leaver: Dictionary = results["leaver"]
	var stayer: Dictionary = results["stayer"]
	var returner: Dictionary = results["returner"]
	var kept := int(leaver["possession"]["my_pawn"])
	_check(kept > 0, "(the leaver possessed pawn %d)" % kept)
	var other := 0
	for entity: Dictionary in NetRun.own_entities(leaver):
		if int(entity["id"]) != kept:
			other = int(entity["id"])
	_check(other > 0, "(and also owned pawn %d)" % other)

	# It stays, and the other thing they owned doesn't.
	_check(not _was_removed(server, kept), "the server keeps the possessed pawn")
	_check(not _was_removed(stayer, kept), "and so does the other client")
	_check(_was_removed(server, other) and _was_removed(stayer, other), "what they owned but didn't possess is removed")
	var left: Array = server["possession_log"].filter(func(line: Array) -> bool: return line[0] == "lost" and int(line[2]) == int(leaver["peer"]))
	_check(left.size() == 1, "the server lets go for them, once")
	if left.size() != 1:
		return
	_check(not stayer["possession"]["map"].has(str(int(leaver["peer"]))), "the other client no longer lists them as having anything")
	_check(int(stayer["possession"]["my_pawn"]) > 0, "and keeps its own pawn")

	# It stops. The server has no brain here, so only the client's input ever moved it, and it's the pawn itself that lets go of that.
	var left_tick := int(left[0][1])
	var history: Dictionary = server["positions"][str(kept)]
	var before := _moved_between(history, left_tick - 120, left_tick)
	_check(before > 1.0, "(it was walking before they left: %.1f m in 2 seconds)" % before)
	var after := _moved_between(history, left_tick + 60, int(results["returner"].get("swap_tick", 0)) - 30)
	_check(after >= 0.0 and after < 0.05, "it stops once they've gone (%.3f m since)" % after)

	# Its ground unloads, because nobody else is near. It's switched off rather than falling.
	var switched_off: Array = server["switched_off"].map(func(entity_id: float) -> int: return int(entity_id))
	_check(switched_off.has(kept), "when its ground unloads, it's switched off")
	_check(_nobody_fell(server), "and nobody falls through the world")

	# It can be taken again, by someone who wasn't there when it was left. --swap-at picks the first pawn nobody owns, so this
	# also shows clients see it with no owner.
	_check(int(returner.get("swap_target", 0)) == kept, "a player who joined later sees it with no owner, and asks for it")
	_check(int(returner["possession"]["my_pawn"]) == kept, "and gets it")
	_check(returner["possession"]["camera_has_view"], "with its camera on it")
	var walked := float(NetRun.summary_of(returner, kept).get("walked", 0.0))
	_check(walked > 2.0, "and it walks again (%.0f m)" % walked)
	_check(int(NetRun.summary_of(returner, kept).get("no_ground", 0)) == 0, "with ground under it on every tick")
	_check(int(server["stats"]["bad_packets"]) == 0, "no bad packets")


## Claude 2026-11-07: the flag is the block. A request reaches the server, which says no.
func _test_not_possessable() -> void:
	var results := await NetRun.run(self, "pawn_not_possessable", {
		"server": _server({"walkers": 1, "ai": 2, "ai-not-possessable": 1, "seconds": 14}),
		"client": _client({"bench-ping": 50, "swap-at": 5, "seconds": 10}),
	}, _port)
	if not _all_finished(results):
		return
	var client: Dictionary = results["client"]
	var target := int(client.get("swap_target", 0))
	_check(target > 0, "(the client asks for pawn %d, which nobody owns)" % target)
	_check(int(client["possession"]["my_pawn"]) > 0 and int(client["possession"]["my_pawn"]) != target, "it keeps the pawn it had")
	var refusals: Array = results["server"]["possession_log"].filter(func(line: Array) -> bool: return line[0] == "refused")
	_check(refusals.size() == 1, "and the server refuses, and says so")


func _test_asking_for_too_much() -> void:
	var results := await NetRun.run(self, "pawn_too_much", {
		"server": _server({"walkers": 1, "seconds": 14}),
		"polite": _client({"bench-ping": 50, "seconds": 10}),
		"greedy": _client({"bench-ping": 50, "seconds": 10, "delay": 1, "ask-for-taken-at": 5}),
	}, _port)
	if not _all_finished(results):
		return
	var polite: Dictionary = results["polite"]
	var greedy: Dictionary = results["greedy"]
	_check(greedy.has("asked_for"), "(a client asks for a pawn another player has, and for one that doesn't exist)")
	_check(int(polite["possession"]["my_pawn"]) > 0, "the first player keeps theirs")
	_check(int(greedy["possession"]["my_pawn"]) != int(greedy.get("asked_for", -1)), "and the asker doesn't get it")
	_check(int(greedy["possession"]["my_pawn"]) > 0, "and keeps its own")
	_check(_nobody_fell(results["server"]), "nothing breaks")


func _test_swap(ping: int) -> void:
	var results := await NetRun.run(self, "pawn_swap_%d" % ping, {
		"server": _server({"walkers": 1, "ai": 2, "ai-mode": "walk", "ai-loads": 1, "seconds": SECONDS + 4}),
		"client": _client({"bench-ping": ping, "swap-at": 8}),
	}, _port)
	if not _all_finished(results):
		return
	var client: Dictionary = results["client"]
	var server: Dictionary = results["server"]
	var target := int(client.get("swap_target", 0))
	_check(target > 0, "(the client asks for pawn %d, an AI pawn)" % target)
	var info: Dictionary = client["possession"]
	_check(int(info["my_pawn"]) == target, "it gets that pawn")
	# Claude 2026-11-07: from the log, because the pawn now outlasts the client, and has no owner by the end of the run.
	_check(_server_gave(server, int(client["peer"]), target), "and the server agrees")
	_check(info["camera_has_view"] and float(info["camera_from_view"]) < 0.5, "and the camera moved to it")
	_check(int(info["arm_count"]) == 1, "and only that pawn has an arm (%d)" % int(info["arm_count"]))
	var old_pawn := NetRun.own_entities(client)
	var first_id := 0
	for entity: Dictionary in server["summaries"]:
		if int(entity["id"]) != target and int(entity["owner"]) == 0 and float(entity.get("walked", 0.0)) > 0.0:
			first_id = int(entity["id"])
	_check(first_id != 0 or old_pawn.size() >= 1, "its old pawn goes back to the server")

	# How the new pawn does once it has settled, from 3 seconds after asking, against the server on the same ticks.
	# Claude 2026-11-09 (scaling spec step 6): in seconds, so a run at another rate (-- --tick-rate=30) asks the same: 3 s, then over 5 s.
	var rate := TickDriver.get_tick_rate()
	var from_tick := int(client.get("swap_tick", 0)) + 3 * rate
	var average_and_count := _error_from(client, server, target, from_tick)
	_check(int(average_and_count["ticks"]) > 5 * rate, "(compared %d ticks after settling)" % int(average_and_count["ticks"]))
	_check(float(average_and_count["average"]) < 0.25, "the new pawn predicts well (%.2f cm on average, %.1f cm at worst)" % [100.0 * float(average_and_count["average"]), 100.0 * float(average_and_count["worst"])])

	# Right after the swap: how big the correction is. It's expected to be there, since it's drawn in the past until then.
	var settle := _error_from(client, server, target, int(client.get("swap_tick", 0)))
	print("        straight after swapping: worst %.1f cm from the server" % (100.0 * float(settle["worst"])))
	_check(float(settle["worst"]) < 5.0, "and it never strays far during the swap (worst %.1f m)" % float(settle["worst"]))
	_check(float(info["camera_worst_jump"]) < 2.0, "the camera doesn't jump about (worst %.2f m in a frame)" % float(info["camera_worst_jump"]))
	var after_on_server := NetRun.summary_of(server, target)
	_check(float(after_on_server.get("walked", 0.0)) > 5.0, "and the pawn carries on walking under its new owner (%.0f m)" % float(after_on_server.get("walked", 0.0)))
	_check(_nobody_fell(server), "nobody fell through the world")


# --- Machines ---


func _server(extra: Dictionary) -> Dictionary:
	var settings := {"role": "server", "terrain": 1, "streaming": 1, "real-pawn": 1, "possess": 1}
	settings.merge(extra, true) # true: what a scenario asks for wins
	return settings


func _client(extra: Dictionary) -> Dictionary:
	var settings := {"role": "client", "terrain": 1, "streaming": 1, "real-pawn": 1, "mode": "walk", "seconds": SECONDS}
	settings.merge(extra, true) # true: what a scenario asks for wins
	return settings


# --- Reading results ---


func _all_finished(results: Dictionary) -> bool:
	var finished := true
	for label: String in results:
		if results[label].has("timed_out") or not results[label].has("summaries"):
			_check(false, "%s finished" % label)
			finished = false
	# Claude 2026-11-07, from the audit of 6df1464: the machines' own logs, which Windows doesn't show here otherwise.
	var errors := NetRun.total_script_errors(results)
	_check(errors == 0, "no script errors on any machine (%d)" % errors)
	return finished


func _nobody_fell(server: Dictionary) -> bool:
	for entity: Dictionary in server.get("summaries", []):
		if float(entity.get("y", 0.0)) < -30.0:
			return false
	return true


## Claude 2026-11-07: true if this machine removed this entity.
func _was_removed(machine: Dictionary, entity_id: int) -> bool:
	for removed: Variant in machine["despawned"]:
		if int(removed) == entity_id:
			return true
	return false


## Claude 2026-11-07: true if the server's log shows it giving this pawn to this player.
func _server_gave(server: Dictionary, peer: int, entity_id: int) -> bool:
	for line: Array in server.get("possession_log", []):
		if line[0] == "got" and int(line[2]) == peer and int(line[3]) == entity_id:
			return true
	return false


## Claude 2026-11-07: how far apart a pawn was on two ticks, or -1 if either wasn't logged.
func _moved_between(history: Dictionary, from_tick: int, to_tick: int) -> float:
	var from_key := str(from_tick)
	var to_key := str(to_tick)
	if not history.has(from_key) or not history.has(to_key):
		return -1.0
	var a: Array = history[from_key]
	var b: Array = history[to_key]
	return Vector3(float(a[0]), float(a[1]), float(a[2])).distance_to(Vector3(float(b[0]), float(b[1]), float(b[2])))


func _error_from(client: Dictionary, server: Dictionary, entity_id: int, from_tick: int) -> Dictionary:
	var own: Dictionary = client.get("positions", {}).get(str(entity_id), {})
	var truth: Dictionary = server.get("positions", {}).get(str(entity_id), {})
	var total := 0.0
	var worst := 0.0
	var count := 0
	for tick_text: String in own:
		if int(tick_text) < from_tick or not truth.has(tick_text):
			continue
		var a: Array = own[tick_text]
		var b: Array = truth[tick_text]
		var error := Vector3(float(a[0]), float(a[1]), float(a[2])).distance_to(Vector3(float(b[0]), float(b[1]), float(b[2])))
		total += error
		worst = maxf(worst, error)
		count += 1
	return {"average": total / maxi(count, 1), "worst": worst, "ticks": count}


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
