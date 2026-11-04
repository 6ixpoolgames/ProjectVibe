## Written by Claude (claude-opus-5-5), 2026-11-04: headless multiplayer self-test, using real connections between separate
## Godot processes on this machine, with a fake bad network added in our own code. Takes a few minutes. Exits 0 on success.
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/netcode/tests/net_selftest.tscn"
## Add -- --only=name to run one scenario.
extends Node

## Holds input with no hook to clean it.
class InputHolder extends Node:
	var want := Vector3.ONE
	var amount := 1.0


var _failures := 0
var _port := 24500
var _only := ""


func _ready() -> void:
	print("--- Multiplayer self-test ---")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--only="):
			_only = argument.trim_prefix("--only=")
	_test_packets()
	await _test_offline()
	await _scenario("connecting", _test_connecting)
	await _scenario("refused", _test_refused)
	await _scenario("late_join_and_leave", _test_late_join_and_leave)
	await _scenario("bad_packets", _test_bad_packets)
	await _scenario("clock", _test_clock)
	await _scenario("inputs", _test_inputs)
	await _scenario("correction", _test_correction)
	await _scenario("interpolation", _test_interpolation)
	await _scenario("lag_compensation", _test_lag_compensation)
	await _scenario("predicted_others", _test_predicted_others)
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _scenario(scenario_name: String, test: Callable) -> void:
	if _only != "" and _only != scenario_name:
		return
	print("  [%s]" % scenario_name)
	_port += 1
	await test.call(scenario_name)


# --- No processes needed ---------------------------------------------------------------------------

## Packets: what goes in comes out, rounded values come back exact, and broken bytes are caught.
func _test_packets() -> void:
	var cases := [
		[Vector3(1.235, -0.002, 300.5), StateEncoding.VECTOR3_MM],
		[Vector3(1.23, -0.5, 3.0), StateEncoding.VECTOR3_CM],
		[Vector2(-4.5, 2.001), StateEncoding.VECTOR2_MM],
		[1.5, StateEncoding.ANGLE_U16],
		[-3.0, StateEncoding.ANGLE_BYTE],
		[0.25, StateEncoding.FLOAT],
		[true, StateEncoding.RAW],
		[false, StateEncoding.RAW],
		[7, StateEncoding.RAW],
		[-9000000000, StateEncoding.RAW],
		[&"name", StateEncoding.RAW],
		[TickStateComponent.MISSING, StateEncoding.RAW],
	]
	var buffer := NetPackets.new_buffer()
	for item: Array in cases:
		NetPackets.write_value(buffer, StateEncoding.quantize(item[0], item[1]), item[1])
	var reading := NetPackets.reader(buffer.data_array)
	var all_match := true
	for item: Array in cases:
		var back: Variant = NetPackets.read_value(reading)
		if back != StateEncoding.quantize(item[0], item[1]):
			all_match = false
			print("        came back different: %s -> %s" % [str(item[0]), str(back)])
	_check(all_match, "packets: every kind of value comes back exactly as it was rounded")
	_check(reading.get_available_bytes() == 0, "packets: nothing left over")

	var pawn_state := NetPackets.new_buffer()
	NetPackets.write_list(pawn_state, [Vector3(1, 2, 3), Vector3(4, 5, 6), 1.0, true], [StateEncoding.VECTOR3_MM, StateEncoding.VECTOR3_MM, StateEncoding.ANGLE_U16, StateEncoding.RAW])
	print("        a pawn's position, velocity, yaw and grounded take %d bytes" % pawn_state.get_size())
	_check(pawn_state.get_size() <= 25, "packets: a pawn's state fits the spec's estimate of 25 bytes")

	var far := NetPackets.new_buffer()
	NetPackets.write_value(far, Vector3(99999, 0, 0), StateEncoding.VECTOR3_MM)
	var far_back: Vector3 = NetPackets.read_value(NetPackets.reader(far.data_array))
	_check(far_back.x > 8000.0 and far_back.x < 8400.0, "packets: a position out of range is clamped, not wrapped around")

	var truncated := NetPackets.new_buffer()
	NetPackets.write_value(truncated, Vector3(1, 2, 3), StateEncoding.VECTOR3_MM)
	var cut := truncated.data_array.slice(0, 5)
	_check(is_same(NetPackets.read_value(NetPackets.reader(cut)), NetPackets.BAD), "packets: a cut-off value reads as bad")
	_check(is_same(NetPackets.read_value(NetPackets.reader(PackedByteArray([200]))), NetPackets.BAD), "packets: an unknown tag reads as bad")
	_check(is_same(NetPackets.read_value(NetPackets.reader(PackedByteArray())), NetPackets.BAD), "packets: nothing at all reads as bad")
	_check(NetPackets.read_list(NetPackets.reader(PackedByteArray([5, 200]))) == null, "packets: a list with a bad value inside reads as bad")
	var huge_claim := NetPackets.new_buffer()
	huge_claim.put_u8(NetPackets.Tag.OTHER)
	huge_claim.put_32(2000000000)
	_check(is_same(NetPackets.read_value(NetPackets.reader(huge_claim.data_array)), NetPackets.BAD), "packets: a forged length is caught before anything is allocated")
	var negative_claim := NetPackets.new_buffer()
	negative_claim.put_u8(NetPackets.Tag.OTHER)
	negative_claim.put_32(-5)
	_check(is_same(NetPackets.read_value(NetPackets.reader(negative_claim.data_array)), NetPackets.BAD), "packets: so is a negative one")
	var with_object := NetPackets.new_buffer()
	NetPackets.write_value(with_object, RefCounted.new(), StateEncoding.RAW)
	_check(is_same(NetPackets.read_value(NetPackets.reader(with_object.data_array)), TickStateComponent.MISSING), "packets: an object is never sent")

	var clock := NetClock.new()
	_check(clock.get_rtt_usec() == 0.0 and clock.estimate_server_tick(0, 16666.0) == 0.0, "clock: empty is harmless")
	clock.add_sample(0, 100000, 1000, 10000.0) # 100 ms round trip, 10 ms ticks, so the server was 5 ticks on by now
	clock.add_sample(1000000, 1200000, 1100, 10000.0) # slower, so ignored for the estimate
	_check(absf(clock.get_rtt_usec() - 150000.0) < 1.0, "clock: round trip is the average")
	_check(absf(clock.estimate_server_tick(100000, 10000.0) - 1005.0) < 0.01, "clock: server tick comes from the fastest ping")
	_check(clock.get_lead_ticks(10000.0, 3) == 11, "clock: lead is half the round trip plus the margin")

	var fake := NetFakeConditions.new()
	var sent: Array = []
	var catch_sent := func(_peer: int, bytes: PackedByteArray, _reliable: bool) -> void: sent.append(bytes[0])
	fake.latency_ms = 10.0
	fake.submit(1, PackedByteArray([1]), true, 0)
	fake.jitter_ms = 50.0
	fake.submit(1, PackedByteArray([2]), true, 0)
	fake.submit(1, PackedByteArray([3]), true, 0)
	fake.release_due(5000, catch_sent)
	_check(sent.is_empty(), "fake network: packets wait")
	fake.release_due(100000, catch_sent)
	_check(sent == [1, 2, 3], "fake network: reliable packets stay in order, whatever the jitter")
	fake.loss = 1.0
	fake.submit(1, PackedByteArray([4]), false, 0)
	fake.submit(1, PackedByteArray([5]), true, 0)
	fake.release_due(1000000, catch_sent)
	_check(sent == [1, 2, 3, 5], "fake network: only unreliable packets get lost")


## Offline: entities spawn with no connection, and lag compensation works on its own.
func _test_offline() -> void:
	var session: NetworkSessionSingleton = get_node("/root/NetworkSession")
	var driver: NetworkTimeSingleton = get_node("/root/NetworkTime")
	var world := Node3D.new()
	add_child(world)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, -0.5, 0)
	world.add_child(floor_body)
	session.world_root = world
	session.register_type("pawn", load(NetRun.NODE_SCENE.replace("net_test_node", "net_test_pawn")))
	NetTestPawn.default_mode = "idle"
	_check(session.get_mode() == NetworkSessionSingleton.Mode.OFFLINE, "offline: no session to begin with")
	_check(session.spawn("nothing_like_this", 1, null) == null, "offline: spawning an unknown type does nothing")
	var shooter_body: NetTestPawn = session.spawn("pawn", 1, Vector3(0, 0.1, 0))
	var target_body: NetTestPawn = session.spawn("pawn", 0, Vector3(5, 0.1, 0))
	_check(shooter_body != null and target_body != null, "offline: entities spawn with no connection")
	var shooter: NetworkEntity = shooter_body.get_node("NetworkEntity")
	var target: NetworkEntity = target_body.get_node("NetworkEntity")
	_check(shooter.is_local and shooter.role == NetworkEntity.Role.AUTHORITY, "offline: your own pawn is the authority")
	_check(session.get_entity(shooter.entity_id) == shooter and session.get_entities().size() == 2, "offline: entities can be looked up")
	target_body.brain = TickSamplePawn.Brain.IDLE
	for i in 10:
		await get_tree().physics_frame
	var old_tick := driver.tick

	# The target moves away. Lag compensation must look at where it was.
	for i in 12:
		await get_tree().physics_frame
		target_body.position += Vector3(0, 0, 0.5)
	await get_tree().physics_frame
	var ticks_ago := float(driver.tick - old_tick)
	var origin := Vector3(0, 1.0, 0)
	var at_old := Vector3(1, 0, 0)
	var hit := LagCompensation.hitscan(shooter, origin, at_old, 20.0, ticks_ago)
	_check(hit.get("entity") == target, "lag compensation: hits where the target was, when the shooter saw it there")
	var live_position := target_body.position
	_check(target_body.position.z > 2.0, "lag compensation: the target really had moved")
	_check(LagCompensation.hitscan(shooter, origin, at_old, 20.0, 0.0).is_empty(), "lag compensation: with no rewind, that same shot misses")
	var to_live := (live_position + Vector3(0, 0.9, 0) - origin).normalized()
	_check(LagCompensation.hitscan(shooter, origin, to_live, 20.0, 0.0).get("entity") == target, "lag compensation: a shot at where it is now hits with no rewind")
	_check(LagCompensation.hitscan(shooter, origin, to_live, 20.0, ticks_ago).is_empty(), "lag compensation: and misses if the shooter was seeing it in the past")
	_check(target_body.position == live_position, "lag compensation: the target is back where it was afterwards")
	var query := PhysicsPointQueryParameters3D.new()
	query.position = live_position + Vector3(0, 0.9, 0)
	_check(target_body.get_world_3d().direct_space_state.intersect_point(query).size() == 1, "lag compensation: and in the collision world")

	var found := LagCompensation.melee(shooter, Vector3(5, 0.9, 0), 0.5, ticks_ago)
	_check(found.size() == 1 and found[0] == target, "lag compensation: a melee swing also checks the past")
	_check(LagCompensation.melee(shooter, Vector3(5, 0.9, 0), 0.5, 0.0).is_empty(), "lag compensation: and misses the present")

	session.rewind_cap_seconds = 0.0
	_check(LagCompensation.hitscan(shooter, origin, at_old, 20.0, ticks_ago).is_empty(), "lag compensation: past the cap, it doesn't rewind that far")
	session.rewind_cap_seconds = 0.35
	_check(LagCompensation.hitscan(shooter, origin, to_live, 20.0, -500.0).get("entity") == target, "lag compensation: a negative claim from a client counts as no rewind")
	session.lag_compensation_enabled = false
	_check(LagCompensation.hitscan(shooter, origin, at_old, 20.0, ticks_ago).is_empty(), "lag compensation: can be turned off")
	session.lag_compensation_enabled = true

	shooter_body._local = false # stops its script overwriting the input this test sets
	shooter_body.wants_attack = true
	shooter_body.aim_dir = to_live
	shooter_body.view_ticks_behind = 0.0
	var health_before := target_body.health
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(target_body.health < health_before and shooter_body.hits_landed == 1, "offline: the attack works as single player")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(shooter_body.hits_landed == 1, "offline: the server's fire rate limit holds, even with the button held")
	shooter_body.wants_attack = false

	var clean: Dictionary = shooter_body.sanitize_network_input({"move_dir": Vector3(50, 0, 0), "wants_sprint": 7, "wants_jump": "yes", "wants_attack": true, "aim_dir": Vector3.ZERO, "view_ticks_behind": "many"})
	_check(absf(clean["move_dir"].length() - 1.0) < 0.001, "sanitizing: a speed hack is limited to full speed")
	_check(clean["wants_sprint"] == false and clean["wants_jump"] == false, "sanitizing: wrong types are replaced")
	_check(clean["aim_dir"] == Vector3.FORWARD and clean["view_ticks_behind"] == 0.0, "sanitizing: a useless aim and a nonsense claim are replaced")
	var not_a_number: Dictionary = shooter_body.sanitize_network_input({"move_dir": Vector3(NAN, 0, 0), "view_ticks_behind": NAN})
	_check(not_a_number["move_dir"] == Vector3.ZERO and not_a_number["view_ticks_behind"] == 0.0, "sanitizing: not-a-number values are replaced")

	# Without a sanitize hook, the input list itself still refuses wrong types and not-a-number.
	var input_check := TickStateComponent.new()
	var holder := InputHolder.new()
	input_check.input_properties = ["want", "amount"]
	holder.add_child(input_check)
	world.add_child(holder)
	var check_tick := driver.tick + 5
	input_check.receive_input(check_tick, {"want": "not a vector", "amount": 2.0})
	input_check.apply_input(check_tick)
	_check(holder.want == Vector3.ONE and holder.amount == 2.0, "input: a wrong type is dropped, the rest still applies")
	input_check.receive_input(check_tick + 1, {"want": Vector3(NAN, 0, 0), "amount": INF})
	input_check.apply_input(check_tick + 1)
	_check(holder.want == Vector3.ONE and holder.amount == 2.0, "input: not-a-number and infinity are dropped")

	var hash_first := session.content_hash()
	session.content_hash_salt = 5
	var hash_salted := session.content_hash()
	session.content_hash_salt = 0
	_check(hash_first != hash_salted and session.content_hash() == hash_first, "content hash: stays the same, and changes when it should, even though it's cached")

	session.despawn(target.entity_id)
	_check(session.get_entity(target.entity_id) == null, "offline: despawn removes an entity")
	session.leave()
	_check(session.get_entities().is_empty(), "offline: leaving removes the rest")
	world.queue_free()
	await get_tree().physics_frame


# --- Real connections ------------------------------------------------------------------------------

func _test_connecting(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 6},
		"a": {"role": "client", "seconds": 5, "mode": "seek"},
		"b": {"role": "client", "seconds": 5, "mode": "seek"},
	}, _port)
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	var b: Dictionary = results["b"]
	_check(not server.has("timed_out") and not a.has("timed_out") and not b.has("timed_out"), "connecting: every machine finished")
	if server.has("timed_out") or a.has("timed_out") or b.has("timed_out"):
		return
	_check(a["joined"] and b["joined"], "connecting: both clients joined")
	_check(server["spawned"].size() == 2, "connecting: the server made a pawn for each client")
	# From what spawned, not what's there at the end: one client quits slightly before the other.
	_check(a["spawned"].size() == 2 and b["spawned"].size() == 2, "connecting: each client sees both pawns")
	var ids_a: Array = a["spawned"].map(func(e: Dictionary) -> int: return int(e["id"]))
	var ids_b: Array = b["spawned"].map(func(e: Dictionary) -> int: return int(e["id"]))
	ids_a.sort()
	ids_b.sort()
	_check(ids_a == ids_b and ids_a.size() == 2 and ids_a[0] != ids_a[1], "connecting: ids are the same everywhere, and different from each other")
	var own_a := NetRun.own_entity(a)
	var own_b := NetRun.own_entity(b)
	_check(int(own_a.get("role", -1)) == NetworkEntity.Role.LOCAL_PREDICTED and int(own_b.get("role", -1)) == NetworkEntity.Role.LOCAL_PREDICTED, "connecting: each client predicts its own pawn")
	_check(int(own_a.get("id", -1)) != int(own_b.get("id", -1)), "connecting: they own different pawns")
	var remote_count := 0
	for entity: Dictionary in a["spawned"]:
		if int(entity["role"]) == NetworkEntity.Role.REMOTE_FOLLOWING:
			remote_count += 1
	_check(remote_count == 1, "connecting: the other client's pawn follows the server")
	for entity: Dictionary in server["summaries"]:
		_check(int(entity["role"]) == NetworkEntity.Role.AUTHORITY, "connecting: the server is the authority for pawn %d" % int(entity["id"]))


func _test_refused(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 4},
		"wrong": {"role": "client", "seconds": 3, "salt": 99},
	}, _port)
	var server: Dictionary = results["server"]
	var wrong: Dictionary = results["wrong"]
	if server.has("timed_out") or wrong.has("timed_out"):
		_check(false, "refused: every machine finished")
		return
	_check(not wrong["joined"], "refused: a client with different content doesn't join")
	_check(String(wrong["refused"]).contains("mismatch"), "refused: and it's told why: %s" % wrong["refused"])
	_check(server["spawned"].is_empty(), "refused: the server made no pawn for it")


func _test_late_join_and_leave(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 9},
		"first": {"role": "client", "seconds": 8, "mode": "seek", "leave-after": 6},
		"late": {"role": "client", "seconds": 8, "delay": 3, "mode": "idle"},
	}, _port)
	var server: Dictionary = results["server"]
	var first: Dictionary = results["first"]
	var late: Dictionary = results["late"]
	if server.has("timed_out") or first.has("timed_out") or late.has("timed_out"):
		_check(false, "late join: every machine finished")
		return
	_check(late["joined"], "late join: a client joining late gets in")
	_check(late["spawned"].size() == 2, "late join: and receives the pawn that already existed, and its own")
	_check(first["disconnected"], "leaving: the leaving client ended its session")
	var first_id := int(NetRun.own_entity(first)["id"])
	_check(server["despawned"].map(func(i: float) -> int: return int(i)).has(first_id), "leaving: the server removed its pawn")
	_check(late["despawned"].size() == 1 and int(late["despawned"][0]) == first_id, "leaving: and so did the other client")
	_check(late["entities"].size() == 1, "leaving: one pawn is left on the other client")


func _test_bad_packets(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 7},
		"victim": {"role": "client", "seconds": 6, "mode": "idle"},
		"attacker": {"role": "client", "seconds": 6, "mode": "idle", "garbage": 1},
	}, _port)
	var server: Dictionary = results["server"]
	var victim: Dictionary = results["victim"]
	if server.has("timed_out") or victim.has("timed_out"):
		_check(false, "bad packets: the server survived and every machine finished")
		return
	_check(true, "bad packets: the server survived 230 broken and forged packets")
	var stats: Dictionary = server["stats"]
	print("        server counted %d bad packets and %d rejected inputs" % [int(stats["bad_packets"]), int(stats["rejected_inputs"])])
	_check(int(stats["rejected_inputs"]) >= 25, "bad packets: forged input for someone else's pawn was rejected")
	_check(int(stats["bad_packets"]) > 0, "bad packets: broken packets were counted and dropped")
	var positions: Dictionary = server["positions"].get(str(int(NetRun.own_entity(victim).get("id", 1))), {})
	var xs: Array = positions.values().map(func(p: Array) -> float: return float(p[0]))
	_check(xs.size() > 10 and absf(xs.max() - xs.min()) < 0.5, "bad packets: the victim's pawn wasn't moved by them")


func _test_clock(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 7, "latency": 50},
		"a": {"role": "client", "seconds": 6, "latency": 50, "mode": "idle"},
	}, _port)
	var a: Dictionary = results["a"]
	if a.has("timed_out"):
		_check(false, "clock: the client finished")
		return
	print("        round trip %.1f ms, lead %.1f ticks, resyncs %d" % [float(a["rtt_ms"]), float(a["lead_ticks"]), int(a["stats"]["resyncs"])])
	_check(float(a["rtt_ms"]) > 95.0 and float(a["rtt_ms"]) < 140.0, "clock: the client measures the fake 100 ms round trip")
	# Half of 100 ms is 3 ticks, plus a margin of 3.
	_check(float(a["lead_ticks"]) > 4.0 and float(a["lead_ticks"]) < 8.5, "clock: the client runs half the round trip plus the margin ahead of the server")
	_check(int(a["stats"]["resyncs"]) <= 1, "clock: and stays there")


func _test_inputs(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 11, "latency": 40, "jitter": 10, "loss": 0.05},
		"a": {"role": "client", "seconds": 10, "latency": 40, "jitter": 10, "loss": 0.05, "mode": "strafe"},
	}, _port)
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	if server.has("timed_out") or a.has("timed_out"):
		_check(false, "inputs: every machine finished")
		return
	var own := NetRun.own_entity(a)
	var own_on_server := NetRun.summary_of(server, int(own["id"]))
	var truth: Dictionary = server["positions"].get(str(int(own["id"])), {})
	var zs: Array = truth.values().map(func(p: Array) -> float: return float(p[2]))
	_check(zs.size() > 100 and absf(zs.max() - zs.min()) > 3.0, "inputs: the server moved the pawn from the client's inputs")
	var lost: int = int(a["fake_lost"])
	var missed: int = int(own_on_server.get("missed_inputs", -1))
	print("        %d input-carrying and other packets lost by the fake network, %d inputs missing on the server over about 8 s" % [lost, missed])
	_check(lost > 10, "inputs: the fake network really did lose packets")
	_check(missed >= 0 and missed <= 5, "inputs: repeating past inputs in each packet covers the losses")
	var error := NetRun.prediction_error(a, server, int(own["id"]))
	print("        own pawn, first prediction against the server: average %.2f cm, worst %.2f cm over %d ticks" % [100.0 * error["average"], 100.0 * error["worst"], error["ticks"]])
	_check(error["ticks"] > 200, "inputs: enough ticks to compare")
	_check(error["average"] < 0.02, "inputs: alone in the arena, prediction matches the server within 2 cm on average")


func _test_correction(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 9, "latency": 50, "shove-at": 400},
		"a": {"role": "client", "seconds": 8, "latency": 50, "mode": "idle"},
	}, _port)
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	if server.has("timed_out") or a.has("timed_out"):
		_check(false, "correction: every machine finished")
		return
	var stats: Dictionary = a["stats"]
	print("        %d corrections, worst %.2f m, largest jump %.2f m" % [int(stats["corrections"]), float(stats["correction_worst"]), float(stats["jump_worst"])])
	_check(server.has("shoved_tick"), "correction: the server shoved the pawn")
	_check(int(stats["corrections"]) >= 1, "correction: the client noticed the prediction was wrong")
	_check(float(stats["correction_worst"]) > 1.5, "correction: by about the size of the shove")
	var own := NetRun.own_entity(a)
	var own_on_server := NetRun.summary_of(server, int(own["id"]))
	var difference := Vector2(float(own["x"]) - float(own_on_server["x"]), float(own["z"]) - float(own_on_server["z"])).length()
	_check(difference < 0.05, "correction: afterwards client and server agree (%.3f m apart)" % difference)
	_check(int(stats["corrections"]) <= 3, "correction: and it doesn't keep correcting")


func _test_interpolation(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 11, "latency": 40, "jitter": 10, "loss": 0.03},
		"mover": {"role": "client", "seconds": 10, "latency": 40, "jitter": 10, "loss": 0.03, "mode": "strafe"},
		"watcher": {"role": "client", "seconds": 10, "latency": 40, "jitter": 10, "loss": 0.03, "mode": "idle"},
	}, _port)
	var server: Dictionary = results["server"]
	var mover: Dictionary = results["mover"]
	var watcher: Dictionary = results["watcher"]
	if server.has("timed_out") or mover.has("timed_out") or watcher.has("timed_out"):
		_check(false, "interpolation: every machine finished")
		return
	var view := NetRun.view_error(watcher, server, int(NetRun.own_entity(mover)["id"]))
	print("        remote pawn as drawn against the server at that moment: average %.2f cm, worst %.2f cm; drawn %.1f ticks behind; largest step %.2f cm in one tick" % [100.0 * view["average"], 100.0 * view["worst"], view["behind_ticks"], 100.0 * view["largest_step"]])
	_check(view["ticks"] > 200, "interpolation: enough ticks to compare")
	_check(view["average"] < 0.05, "interpolation: a remote pawn is drawn where it really was")
	# Half of 80 ms is about 3 ticks ahead, snapshots arrive about 3 ticks old, plus 3 margin and 6 of interpolation.
	_check(view["behind_ticks"] > 10.0 and view["behind_ticks"] < 20.0, "interpolation: it's drawn about a round trip plus 100 ms behind")
	# 5 m/s is 8.3 cm per tick. A big step would look like a stutter.
	_check(view["largest_step"] < 0.25, "interpolation: it moves smoothly, without jumps")
	var watcher_bytes := NetRun.bandwidth(watcher)
	print("        a client receives %.1f KB/s and sends %.1f KB/s" % [watcher_bytes["received"] / 1000.0, watcher_bytes["sent"] / 1000.0])


func _shooter_results(run_name: String, latency: int, extra: Dictionary) -> Dictionary:
	_port += 1
	var server_settings: Dictionary = {"role": "server", "seconds": 13, "latency": latency}
	var shooter_settings: Dictionary = {"role": "client", "seconds": 12, "latency": latency, "mode": "shoot"}
	server_settings.merge(extra.get("server", {}))
	shooter_settings.merge(extra.get("shooter", {}))
	var results := await NetRun.run(self, run_name, {
		"server": server_settings,
		"target": {"role": "client", "seconds": 12, "latency": latency, "mode": "strafe"},
		"shooter": shooter_settings,
	}, _port)
	var totals := {"shots": 0, "hits": 0, "finished": not (results["server"].has("timed_out") or results["shooter"].has("timed_out"))}
	if totals["finished"]:
		for entity: Dictionary in results["server"]["summaries"]:
			totals["shots"] += int(entity["shots"])
			totals["hits"] += int(entity["hits"])
	return totals


func _test_lag_compensation(run_name: String) -> void:
	var rewound := await _shooter_results(run_name + "_on", 50, {})
	var control := await _shooter_results(run_name + "_off", 50, {"server": {"no-rewind": 1}})
	var past_cap := await _shooter_results(run_name + "_cap", 200, {})
	if not (rewound["finished"] and control["finished"] and past_cap["finished"]):
		_check(false, "lag compensation: every machine finished")
		return
	print("        100 ms ping: %d of %d shots hit with lag compensation, %d of %d without. 400 ms ping: %d of %d" % [rewound["hits"], rewound["shots"], control["hits"], control["shots"], past_cap["hits"], past_cap["shots"]])
	_check(rewound["shots"] >= 8, "lag compensation: shots were fired")
	_check(rewound["hits"] >= rewound["shots"] * 0.8, "lag compensation: aiming at a moving target where it's drawn hits at 100 ms ping")
	_check(control["hits"] <= control["shots"] * 0.4, "lag compensation: turned off, the same shots mostly miss")
	_check(past_cap["hits"] <= past_cap["shots"] * 0.5, "lag compensation: at 400 ms ping, past the cap, shooters have to lead")


func _test_predicted_others(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 10, "latency": 40, "predicted": 1},
		"mover": {"role": "client", "seconds": 9, "latency": 40, "mode": "strafe", "predicted": 1},
		"watcher": {"role": "client", "seconds": 9, "latency": 40, "mode": "idle", "predicted": 1},
	}, _port)
	var server: Dictionary = results["server"]
	var mover: Dictionary = results["mover"]
	var watcher: Dictionary = results["watcher"]
	if server.has("timed_out") or mover.has("timed_out") or watcher.has("timed_out"):
		_check(false, "predicted others: every machine finished")
		return
	var mover_id := int(NetRun.own_entity(mover)["id"])
	var role := int(NetRun.summary_of(watcher, mover_id).get("role", -1))
	_check(role == NetworkEntity.Role.REMOTE_PREDICTED, "predicted others: with is_predicted on, another client's pawn is predicted")
	var error := NetRun.prediction_error(watcher, server, mover_id)
	print("        another client's pawn, predicted, against the server on the same tick: average %.2f cm, worst %.2f cm" % [100.0 * error["average"], 100.0 * error["worst"]])
	_check(error["ticks"] > 200, "predicted others: enough ticks to compare")
	_check(error["average"] < 0.15, "predicted others: a steady mover is predicted close to where it really is, not in the past")


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
