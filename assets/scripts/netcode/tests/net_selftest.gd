## Written by Claude (claude-opus-5-5), 2026-11-04: headless multiplayer self-test, using real connections between separate
## Godot processes on this machine, with a fake bad network added in our own code. Takes about 6 minutes. Exits 0 on success.
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/netcode/tests/net_selftest.tscn"
## Add -- --only=name to run one scenario.
extends Node

## Has a position and velocity to extrapolate from.
class Mover3D extends Node3D:
	var velocity := Vector3.ZERO


## Holds input with no hook to clean it.
class InputHolder extends Node:
	var want := Vector3.ONE
	var amount := 1.0


var _failures := 0
var _port := NetRun.first_port()
var _only := ""


func _ready() -> void:
	print("--- Multiplayer self-test ---")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--only="):
			_only = argument.trim_prefix("--only=")
	_test_packets()
	_test_encoding_choice()
	await _test_offline()
	await _scenario("connecting", _test_connecting)
	await _scenario("refused", _test_refused)
	await _scenario("late_join_and_leave", _test_late_join_and_leave)
	await _scenario("bad_packets", _test_bad_packets)
	await _scenario("clock", _test_clock)
	await _scenario("inputs", _test_inputs)
	await _scenario("correction", _test_correction)
	await _scenario("custom_state", _test_custom_state)
	await _scenario("mixed_encoding", _test_mixed_encoding)
	await _scenario("interpolation", _test_interpolation)
	await _scenario("lag_compensation", _test_lag_compensation)
	await _scenario("predicted_others", _test_predicted_others)
	await _scenario("dilation", _test_dilation)
	await _scenario("dilation_ramp", _test_dilation_ramp)
	await _scenario("prediction_off", _test_prediction_off)
	await _scenario("reconciliation_off", _test_reconciliation_off)
	await _scenario("interpolation_off", _test_interpolation_off)
	await _scenario("live_switches", _test_live_switches)
	await _scenario("bench_ping", _test_bench_ping)
	await _scenario("adaptive_interpolation", _test_adaptive_interpolation)
	await _scenario("worst_case", _test_worst_case)
	await _scenario("terrain", _test_terrain)
	await _scenario("hitches", _test_hitches)
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _scenario(scenario_name: String, test: Callable) -> void:
	if _only != "" and _only != scenario_name:
		return
	print("  [%s]" % scenario_name)
	_port += 1
	await test.call(scenario_name)


# --- No processes needed ---------------------------------------------------------------------------

## Claude 2026-11-05: which encoding a session picks. The missing library itself can't be tested here, but turning it off takes the
## same path through the code.
func _test_encoding_choice() -> void:
	var session: NetworkSessionSingleton = get_node("/root/NetworkSession")
	_check(session._make_codec(NetPackets.PROTOCOL_VERSION) != null, "encoding: C++ is used when the library is here")
	_check(session._make_codec(NetPackets.PROTOCOL_VERSION + 1) == null, "encoding: a library built for another packet format isn't used")
	session.use_native_encoding = false
	_check(session._make_codec(NetPackets.PROTOCOL_VERSION) == null, "encoding: turned off, it uses GDScript")
	session.use_native_encoding = true


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
	_check(clock.get_lead_ticks(10000.0, 3, true) == 8, "clock: or the fastest recent one, which a spike can't inflate")

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
	_test_fake_conditions()


func _test_fake_conditions() -> void:
	var sent: Array = []
	var catch_sent := func(_peer: int, bytes: PackedByteArray, _reliable: bool) -> void: sent.append(bytes[0])
	var rough := NetFakeConditions.new()
	rough.set_seed(1)
	_check(not rough.is_active(), "fake network: off until something is set")
	rough.start_burst(0, 1.0)
	_check(rough.is_active() and rough.is_in_burst(500000) and not rough.is_in_burst(1500000), "fake network: a burst lasts as long as it was asked to")
	rough.submit(1, PackedByteArray([6]), false, 0)
	rough.submit(1, PackedByteArray([7]), true, 0)
	rough.release_due(500000, catch_sent)
	_check(sent.is_empty() and rough.packets_lost == 1, "fake network: in a burst, unreliable packets are lost and reliable ones wait")
	rough.release_due(1100000, catch_sent)
	_check(sent == [7], "fake network: reliable packets arrive when the burst ends")

	rough.clear()
	sent.clear()
	rough.start_spike(2000000, 1.0, 100.0)
	rough.submit(1, PackedByteArray([8]), false, 2000000)
	rough.release_due(2050000, catch_sent)
	_check(sent.is_empty(), "fake network: a spike adds to the delay")
	rough.release_due(2110000, catch_sent)
	_check(sent == [8], "fake network: and it arrives after that")
	rough.release_due(9000000, catch_sent)
	_check(not rough.is_active(), "fake network: once a burst and a spike are over, it goes back to off")

	var ramp := NetFakeConditions.new()
	ramp.timeline = [[0.0, 10.0], [10.0, 110.0], [12.0, 110.0]]
	ramp.update(3000000)
	_check(is_equal_approx(ramp.latency_ms, 10.0), "fake network: a timeline starts at its first value")
	ramp.update(8000000)
	_check(is_equal_approx(ramp.latency_ms, 60.0), "fake network: and moves in a straight line between its points")
	ramp.update(30000000)
	_check(is_equal_approx(ramp.latency_ms, 110.0), "fake network: and holds at the end")

	var wander := NetFakeConditions.new()
	wander.set_seed(2)
	wander.jitter_ms = 10.0
	wander.jitter_variation = 1.0
	var seen_low := 99.0
	var seen_high := 0.0
	for i in 400:
		wander.update(i * 100000)
		seen_low = minf(seen_low, wander.get_current_jitter_ms())
		seen_high = maxf(seen_high, wander.get_current_jitter_ms())
	_check(seen_low >= 0.0 and seen_high <= 20.0 and seen_high - seen_low > 8.0, "fake network: jitter itself wanders, within its limits")

	sent.clear()
	var doubles := NetFakeConditions.new()
	doubles.duplicate_chance = 1.0
	doubles.submit(1, PackedByteArray([9]), false, 0)
	doubles.submit(1, PackedByteArray([10]), true, 0)
	doubles.release_due(100000, catch_sent)
	_check(sent.count(9) == 2 and sent.count(10) == 1, "fake network: unreliable packets can arrive twice, reliable ones never")

	sent.clear()
	var shuffled := NetFakeConditions.new()
	shuffled.reorder_chance = 1.0
	shuffled.submit(1, PackedByteArray([11]), false, 0)
	shuffled.reorder_chance = 0.0
	shuffled.submit(1, PackedByteArray([12]), false, 1000)
	shuffled.release_due(200000, catch_sent)
	_check(sent == [12, 11], "fake network: a reordered packet arrives after a later one")

	var preset := NetFakeConditions.new()
	preset.apply_preset("worst")
	_check(is_equal_approx(preset.latency_ms, 125.0) and preset.is_active(), "fake network: a preset gives each direction half the round trip")
	_check(preset.spike_ms == 500.0, "fake network: but a spike keeps its full size, because each direction spikes on its own")
	preset.apply_preset("off")
	_check(not preset.is_active(), "fake network: the off preset turns it all off")


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

	_test_content_hash(session)
	var hash_first := session.content_hash()
	session.content_hash_salt = 5
	var hash_salted := session.content_hash()
	session.content_hash_salt = 0
	_check(hash_first != hash_salted and session.content_hash() == hash_first, "content hash: stays the same, and changes when it should, even though it's cached")

	_test_bench(session)
	var following := TickStateComponent.new()
	var following_holder := InputHolder.new()
	following.state_properties = ["want"]
	following.rollback_mode = TickStateComponent.RollbackMode.FOLLOW_SERVER
	following_holder.add_child(following)
	world.add_child(following_holder)
	following.receive_authoritative_state(1000, {"want": Vector3(2, 0, 0)})
	following.follow_server_at(1000.5)
	_check(following_holder.want == Vector3(2, 0, 0), "follow server: with nothing to blend to, it holds where it was")
	var late_state := TickStateComponent.new()
	late_state.state_properties = ["position", "velocity"]
	late_state.rollback_mode = TickStateComponent.RollbackMode.FOLLOW_SERVER
	var late_mover := Mover3D.new()
	late_mover.add_child(late_state)
	world.add_child(late_mover)
	late_state.receive_authoritative_state(1000, {"position": Vector3(1, 0, 0), "velocity": Vector3(60, 0, 0)})
	late_state.follow_server_at(1002.0, true)
	_check(late_mover.position.distance_to(Vector3(3, 0, 0)) < 0.01, "extrapolation: on, past the newest snapshot it moves on its velocity")
	late_state.follow_server_at(1002.0, false)
	_check(late_mover.position.distance_to(Vector3(1, 0, 0)) < 0.01, "extrapolation: off, it holds at the newest snapshot")

	var base_ticks: float = session.interpolation_seconds * driver.get_tick_rate()
	var top_ticks: float = session.max_interpolation_seconds * driver.get_tick_rate()
	session._snapshot_jitter_usec = 0.0
	_check(is_equal_approx(session._interpolation_ticks(), base_ticks), "adaptive interpolation: with no jitter, it draws the normal distance back")
	session._snapshot_jitter_usec = 1000000.0 / driver.get_tick_rate()
	_check(is_equal_approx(session._interpolation_ticks(), base_ticks + 2.0), "adaptive interpolation: with jitter, further back")
	session._snapshot_jitter_usec = 10000000.0
	_check(is_equal_approx(session._interpolation_ticks(), top_ticks), "adaptive interpolation: never past its limit")
	session.adaptive_interpolation_enabled = false
	_check(is_equal_approx(session._interpolation_ticks(), base_ticks), "adaptive interpolation: off, it stays at the normal distance")
	session.adaptive_interpolation_enabled = true
	session._snapshot_jitter_usec = 0.0

	var factor_before: float = driver.tick_factor
	session._update_dilation(5, NetworkSessionSingleton.NO_MARGIN)
	_check(driver.tick_factor == 1.0, "dilation: no slowing down until the whole 5 seconds have been seen")
	session._update_dilation(5, 5)
	_check(driver.tick_factor < 1.0 and driver.tick_factor >= 0.97, "dilation: inputs safely early for 5 seconds, it slows down a little")
	session._update_dilation(-2, -2)
	_check(driver.tick_factor > 1.0 and driver.tick_factor <= 1.05, "dilation: inputs late, it speeds up a little")
	session._update_dilation(1, 1)
	_check(driver.tick_factor == 1.0, "dilation: in the wanted range, it runs at normal speed")
	driver.tick_factor = factor_before

	var was_mode := session._mode
	session._mode = NetworkSessionSingleton.Mode.SERVER
	session._peers[77] = {"welcomed": true, "margins": [], "acknowledged_snapshot": -1, "connected_at": 0}
	session._note_input_timing(77, 100, 50, 95)
	session._note_input_timing(77, 100, 50, 96)
	session._note_input_timing(77, 99, 50, 96)
	_check(session._peers[77]["margins"] == [5], "dilation: a duplicate or overtaken packet isn't counted as late")
	session._note_input_timing(77, 101, 40, 97)
	_check(session._peers[77]["acknowledged_snapshot"] == 50, "rewind claim: what a client acknowledges can't go backwards")
	session._note_input_timing(77, 102, 9000, 98)
	_check(session._peers[77]["acknowledged_snapshot"] == 50, "rewind claim: and it can't be from the future")
	# Claude 2026-11-05: a broken input packet tells the timing nothing.
	var margins_before: int = session._peers[77]["margins"].size()
	var real_owner := target.owner_peer
	target.owner_peer = 77
	var broken_input := NetPackets.new_buffer()
	broken_input.put_u8(NetPackets.Type.INPUT)
	broken_input.put_u32(target.entity_id)
	broken_input.put_u32(500)
	broken_input.put_32(90)
	broken_input.put_u8(2)
	broken_input.put_u8(200) # claims a list of 200 values, and then the packet ends
	session._on_input(77, broken_input.data_array, 490)
	target.owner_peer = real_owner
	_check(session._peers[77]["margins"].size() == margins_before and int(session._peers[77]["newest_input"]) < 500, "inputs: a broken packet doesn't count towards the timing")

	# Claude 2026-11-05: what one client may send.
	var limits_before: Array = [session.max_packets_per_second, session.max_bytes_per_second, session.max_packet_bytes]
	var ping := PackedByteArray([NetPackets.Type.PING, 0, 0, 0, 0, 0, 0, 0, 0])
	session.max_packets_per_second = 5
	var allowed := 0
	for i in 200:
		if session._within_limits(77, ping):
			allowed += 1
	_check(allowed >= 5 and allowed < 200, "limits: packets past the rate are dropped (%d of 200 got through)" % allowed)
	session.max_packets_per_second = 0
	session.max_bytes_per_second = 90
	session._peers[77].erase("limit_second")
	allowed = 0
	for i in 200:
		if session._within_limits(77, ping):
			allowed += 1
	_check(allowed >= 10 and allowed < 200, "limits: so are bytes past the rate (%d of 200 got through)" % allowed)
	session.max_bytes_per_second = 0
	var oversized := PackedByteArray()
	oversized.resize(session.max_packet_bytes + 1)
	oversized[0] = NetPackets.Type.INPUT
	_check(not session._within_limits(77, oversized), "limits: so is a packet over the size limit")
	_check(not session._within_limits(12345, ping), "limits: so is anything from a peer the server doesn't know")
	session._peers[77]["welcomed"] = false
	_check(not session._within_limits(77, ping), "limits: before the handshake, a client can't send anything else")
	_check(session._within_limits(77, PackedByteArray([NetPackets.Type.HELLO])), "limits: except the packet that starts the handshake")
	session._peers[77]["welcomed"] = true
	session.max_packets_per_second = limits_before[0]
	session.max_bytes_per_second = limits_before[1]
	session.max_packet_bytes = limits_before[2]

	session.allow_debug_commands = true
	var switch_packet := NetPackets.new_buffer()
	switch_packet.put_u8(NetPackets.Type.DEBUG_SWITCH)
	NetPackets.write_value(switch_packet, "lag_compensation_enabled", StateEncoding.RAW)
	NetPackets.write_value(switch_packet, false, StateEncoding.RAW)
	session._peers[77]["welcomed"] = false
	session._on_debug_switch(77, switch_packet.data_array)
	_check(session.lag_compensation_enabled, "switches: a client that hasn't passed the handshake can't change anything")
	session._peers[77]["welcomed"] = true
	session._on_debug_switch(77, switch_packet.data_array)
	_check(not session.lag_compensation_enabled, "switches: one that has can, if allowed")
	session.lag_compensation_enabled = true
	# Claude 2026-11-05: the server only saves inputs when clients predicting the entity need them.
	session._refresh_entities()
	_check(target.state.skip_input_capture, "input saving: a server skips it")
	var predicted_packet := NetPackets.new_buffer()
	predicted_packet.put_u8(NetPackets.Type.DEBUG_SWITCH)
	NetPackets.write_value(predicted_packet, "default_predicted", StateEncoding.RAW)
	NetPackets.write_value(predicted_packet, true, StateEncoding.RAW)
	session._on_debug_switch(77, predicted_packet.data_array)
	_check(not target.state.skip_input_capture, "input saving: unless clients are predicting, even when switched on live")
	session.default_predicted = false
	session.allow_debug_commands = false
	session._mode = was_mode
	session._peers.erase(77)
	session._refresh_entities()
	_check(not target.state.skip_input_capture, "input saving: offline keeps it")

	var list_before: Array[NetworkEntity] = session.get_entities()
	_check(session.get_entities() == list_before, "entity list: it's kept, not rebuilt each time")
	var freed_body: Node = session.spawn("pawn", 0, Vector3(9, 0.1, 9))
	var freed_entity: NetworkEntity = freed_body.get_node("NetworkEntity")
	var freed_id := freed_entity.entity_id
	_check(session.get_entities().has(freed_entity), "entity list: a new entity joins it")
	freed_body.free()
	_check(session.get_entity(freed_id) == null and session.get_entities().size() == 2, "entity list: one freed directly by the game leaves it")

	session._peers[77] = {"welcomed": true, "acknowledged_snapshot": 100}
	var interpolation_limit: float = session.max_interpolation_seconds * driver.get_tick_rate()
	_check(session.limit_view_ticks_behind(77, 8.0, 103) == 8.0, "rewind claim: a believable claim is left alone")
	_check(is_equal_approx(session.limit_view_ticks_behind(77, 500.0, 103), 3.0 + interpolation_limit + 1.0), "rewind claim: a low-ping client can't claim more than its acknowledgements allow")
	_check(session.limit_view_ticks_behind(77, 8.0, 100 + roundi(session.rewind_cap_seconds * driver.get_tick_rate()) + 1) == 0.0, "rewind claim: an acknowledgement older than the cap gets no rewind")
	session._peers[77]["acknowledged_snapshot"] = -1
	_check(session.limit_view_ticks_behind(77, 8.0, 103) == 0.0, "rewind claim: a client that has seen nothing gets no rewind")
	_check(session.limit_view_ticks_behind(999, 8.0, 103) == 8.0, "rewind claim: the host's own pawn and AI aren't limited")
	session._peers.erase(77)

	session.despawn(target.entity_id)
	_check(session.get_entity(target.entity_id) == null, "offline: despawn removes an entity")
	session.leave()
	_check(session.get_entities().is_empty(), "offline: leaving removes the rest")
	world.queue_free()
	await get_tree().physics_frame


# Claude 2026-11-05: two machines that would simulate differently must not be able to play together.
func _test_content_hash(session: NetworkSessionSingleton) -> void:
	var fresh_hash := func() -> int:
		session._hash_is_cached = false
		return session.content_hash()
	var started := Time.get_ticks_usec()
	var first: int = fresh_hash.call()
	print("        hashing the project took %.1f ms" % ((Time.get_ticks_usec() - started) / 1000.0))
	_check(fresh_hash.call() == first, "content hash: the same content gives the same number")

	var gravity: Variant = ProjectSettings.get_setting("physics/3d/default_gravity")
	ProjectSettings.set_setting("physics/3d/default_gravity", 20.0)
	_check(fresh_hash.call() != first, "content hash: a physics setting changes it")
	ProjectSettings.set_setting("physics/3d/default_gravity", gravity)

	var folder := "user://net_test/%d/hash_test" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(folder)
	var write := func(file_name: String, text: String) -> void:
		var file := FileAccess.open(folder.path_join(file_name), FileAccess.WRITE)
		file.store_string(text)
		file.close()
	var hash_of_folder := func() -> int:
		var parts := PackedStringArray()
		session._add_file_hashes(folder, parts)
		return hash("|".join(parts))
	write.call("script.gd", "one")
	write.call("notes.txt", "one")
	var folder_before: int = hash_of_folder.call()
	write.call("notes.txt", "two")
	_check(hash_of_folder.call() == folder_before, "content hash: other kinds of file don't count")
	write.call("script.gd", "two")
	_check(hash_of_folder.call() != folder_before, "content hash: changing a script does")
	DirAccess.remove_absolute(folder.path_join("script.gd"))
	DirAccess.remove_absolute(folder.path_join("notes.txt"))

	ProjectSettings.set_setting(NetworkSessionSingleton.BUILD_ID_SETTING, "build 123")
	var named: int = fresh_hash.call()
	_check(named != first, "content hash: a build id changes it")
	ProjectSettings.set_setting(NetworkSessionSingleton.BUILD_ID_SETTING, "build 124")
	_check(fresh_hash.call() != named, "content hash: and two build ids differ")
	ProjectSettings.set_setting(NetworkSessionSingleton.BUILD_ID_SETTING, null)
	_check(fresh_hash.call() == first, "content hash: and with none, it's back to reading files")


func _test_bench(session: NetworkSessionSingleton) -> void:
	var bench := NetTestBench.new()
	add_child(bench)
	_check(bench.handle_key(KEY_BRACKETRIGHT) and is_equal_approx(session.fake.latency_ms, 5.0) and is_equal_approx(session.fake_in.latency_ms, 5.0), "bench: ] raises the ping, half each way")
	bench.handle_key(KEY_BRACKETLEFT)
	bench.handle_key(KEY_BRACKETLEFT)
	_check(session.fake.latency_ms == 0.0, "bench: [ lowers it, and it can't go below zero")
	bench.handle_key(KEY_EQUAL)
	_check(is_equal_approx(session.fake.jitter_ms, 2.5), "bench: = raises jitter")
	bench.handle_key(KEY_MINUS)
	_check(session.fake.jitter_ms == 0.0, "bench: - lowers it")
	bench.handle_key(KEY_PERIOD)
	_check(is_equal_approx(session.fake.loss, 0.005), "bench: . raises loss")
	bench.handle_key(KEY_COMMA)
	_check(is_equal_approx(session.fake.loss, 0.0), "bench: , lowers it")
	bench.handle_key(KEY_APOSTROPHE)
	_check(is_equal_approx(session.fake.jitter_variation, 0.1), "bench: ' makes jitter wander more")
	bench.handle_key(KEY_SEMICOLON)
	_check(is_equal_approx(session.fake.jitter_variation, 0.0), "bench: ; makes it wander less")
	bench.handle_key(KEY_F5)
	_check(is_equal_approx(session.fake.latency_ms, 125.0) and is_equal_approx(session.fake_in.latency_ms, 125.0) and bench.preset_name == "worst", "bench: F5 is the worst case preset")
	bench.handle_key(KEY_F1)
	_check(not session.fake.is_active(), "bench: F1 turns it all off")
	bench.handle_key(KEY_B)
	_check(session.fake.is_in_burst(Time.get_ticks_usec()), "bench: B starts a burst")
	bench.handle_key(KEY_N)
	_check(session.fake.is_in_spike(Time.get_ticks_usec()), "bench: N starts a spike")
	session.fake.clear()
	session.fake_in.clear()
	session.fake.apply_preset("off")
	session.fake_in.apply_preset("off")
	var was_on := session.is_feature_on("prediction_enabled")
	bench.handle_key(KEY_1)
	_check(session.is_feature_on("prediction_enabled") != was_on, "bench: 1 switches the first feature")
	bench.handle_key(KEY_1)
	_check(session.is_feature_on("prediction_enabled") == was_on, "bench: and back")
	_check(not bench.handle_key(KEY_Z), "bench: other keys are left alone")
	_check(bench.status_text().contains("time_dilation_enabled"), "bench: the panel lists the features")
	session.set_feature("not_a_feature", true)
	_check(not session.is_feature_on("not_a_feature"), "switches: an unknown feature is ignored")
	bench.free()


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
	# Claude 2026-11-05: the same code with different physics simulates differently, so it's refused too.
	_port += 1
	var other_physics := await NetRun.run(self, run_name + "_physics", {
		"server": {"role": "server", "seconds": 4},
		"wrong": {"role": "client", "seconds": 3, "gravity": 20},
	}, _port)
	_check(not other_physics["wrong"].has("timed_out") and not other_physics["wrong"]["joined"], "refused: so is one with different physics settings")


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
	_check(int(stats["packets_over_limit"]) > 2000, "bad packets: a flood past the limit was dropped (%d)" % int(stats["packets_over_limit"]))
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
	_check(float(a["lead_ticks"]) > 4.0 and float(a["lead_ticks"]) < 9.0, "clock: the client runs half the round trip plus the margin ahead of the server")
	_check(int(a["stats"]["resyncs"]) <= 1, "clock: and stays there")
	_check(int(a["missed_inputs"]) <= 3, "clock: time spent syncing doesn't count as missed input (%d)" % int(a["missed_inputs"]))


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


# Claude 2026-11-05: state in save_state and load_state used to stay on each machine, so a client never learned the server had
# changed it, and stayed wrong for good.
func _test_custom_state(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 9, "latency": 50, "custom": 1, "bonus-at": 400},
		"a": {"role": "client", "seconds": 8, "latency": 50, "mode": "idle", "custom": 1},
	}, _port)
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	if server.has("timed_out") or a.has("timed_out"):
		_check(false, "custom state: every machine finished")
		return
	_check(server.has("bonus_tick"), "custom state: the server changed the value")
	var own := NetRun.own_entity(a)
	var own_on_server := NetRun.summary_of(server, int(own["id"]))
	_check(int(own_on_server["bonus"]) == 1 and int(own["bonus"]) == 1, "custom state: the client got the server's value (%s)" % str(own["bonus"]))
	# total goes up by one every tick from the change onward, so a replay from the wrong place would leave it off.
	var since_change_client := int(own["tick"]) - int(server.get("bonus_tick", 0))
	var since_change_server := int(own_on_server["tick"]) - int(server.get("bonus_tick", 0))
	print("        total %d on the client after %d ticks, %d on the server after %d" % [int(own["total"]), since_change_client, int(own_on_server["total"]), since_change_server])
	_check(absi(int(own["total"]) - since_change_client) <= 2, "custom state: the client replayed from the corrected value")
	_check(absi(int(own_on_server["total"]) - since_change_server) <= 2, "custom state: the server counted the same way")
	_check(int(a["stats"]["corrections"]) >= 1 and int(a["stats"]["corrections"]) <= 3, "custom state: one correction, and it doesn't keep correcting (%d)" % int(a["stats"]["corrections"]))


## Claude 2026-11-05: a machine using C++ snapshots and one using GDScript play together, whichever is the server. The custom
## pawn is used because its state takes the slowest path through the format.
func _test_mixed_encoding(run_name: String) -> void:
	for server_uses_cpp: bool in [true, false]:
		var server: Dictionary = {"role": "server", "seconds": 8, "latency": 30, "custom": 1, "bonus-at": 300}
		var client: Dictionary = {"role": "client", "seconds": 7, "latency": 30, "mode": "idle", "custom": 1}
		(client if server_uses_cpp else server)["script-encoding"] = 1
		var label := "C++ server, GDScript client" if server_uses_cpp else "GDScript server, C++ client"
		_port += 1
		var results := await NetRun.run(self, "%s_%s" % [run_name, server_uses_cpp], {"server": server, "a": client}, _port)
		var a: Dictionary = results["a"]
		if results["server"].has("timed_out") or a.has("timed_out"):
			_check(false, "%s: every machine finished" % label)
			continue
		_check(results["server"]["native_encoding"] == server_uses_cpp and a["native_encoding"] != server_uses_cpp, "%s: each machine used what it was told to" % label)
		_check(int(a["stats"]["snapshots_received"]) > 100, "%s: snapshots arrive (%d)" % [label, int(a["stats"]["snapshots_received"])])
		_check(int(a["stats"]["bad_packets"]) == 0 and int(results["server"]["stats"]["bad_packets"]) == 0, "%s: no packet was refused" % label)
		var own := NetRun.own_entity(a)
		_check(int(own["bonus"]) == 1, "%s: the client got the server's value" % label)
		_check(int(a["stats"]["corrections"]) <= 3, "%s: predictions still match (%d corrections)" % [label, int(a["stats"]["corrections"])])


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


## A client on a steady connection, with dilation on and off.
func _dilation_results(run_name: String, client_extra: Dictionary) -> Dictionary:
	_port += 1
	var client: Dictionary = {"role": "client", "seconds": 16, "mode": "strafe"}
	client.merge(client_extra)
	return await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 17},
		"a": client,
	}, _port)


func _margin_average(machine: Dictionary) -> float:
	var stats: Dictionary = machine["stats"]
	return float(stats["margin_total"]) / maxf(float(stats["margin_reports"]), 1.0)


func _test_dilation(run_name: String) -> void:
	var results := await _dilation_results(run_name + "_on", {"latency": 100, "jitter": 10})
	var fixed := await _dilation_results(run_name + "_off", {"latency": 100, "jitter": 10, "off": "time_dilation_enabled"})
	if results["a"].has("timed_out") or fixed["a"].has("timed_out"):
		_check(false, "dilation: every machine finished")
		return
	var a: Dictionary = results["a"]
	var f: Dictionary = fixed["a"]
	print("        with dilation: inputs arrive %.1f ticks early on average, lowest %d, speed %.3f to %.3f, %d missed, %d resyncs" % [_margin_average(a), int(a["stats"]["margin_lowest"]), float(a["stats"]["speed_lowest"]), float(a["stats"]["speed_highest"]), int(a["missed_inputs"]), int(a["stats"]["resyncs"])])
	print("        fixed lead:    inputs arrive %.1f ticks early on average, lowest %d, speed %.3f to %.3f, %d missed, %d resyncs" % [_margin_average(f), int(f["stats"]["margin_lowest"]), float(f["stats"]["speed_lowest"]), float(f["stats"]["speed_highest"]), int(f["missed_inputs"]), int(f["stats"]["resyncs"])])
	_check(float(f["stats"]["speed_lowest"]) == 1.0 and float(f["stats"]["speed_highest"]) == 1.0, "dilation: turned off, the client always runs at normal speed")
	# It waits 5 safe seconds before giving back any lead, so what counts is where it ends up, not the average on the way there.
	_check(int(a["margin_last"]) >= 1 and int(a["margin_last"]) <= 2, "dilation: on a steady connection it settles with inputs 1 to 2 ticks early (%d)" % int(a["margin_last"]))
	_check(float(a["stats"]["speed_lowest"]) >= 0.96 and float(a["stats"]["speed_highest"]) <= 1.06, "dilation: speed changes stay within a few percent")
	_check(int(a["stats"]["margin_lowest"]) >= -1, "dilation: inputs still arrive on time")
	_check(int(a["stats"]["resyncs"]) == 0, "dilation: it never needs to jump")
	_check(int(a["missed_inputs"]) <= 5, "dilation: almost no inputs are missed")


func _test_dilation_ramp(run_name: String) -> void:
	# Ping climbs from 10 ms to 120 ms and back, which a fixed lead can't follow without jumping.
	var timeline := "0:5,4:5,7:60,10:60,13:5,16:5"
	var results := await _dilation_results(run_name + "_on", {"timeline": timeline})
	var fixed := await _dilation_results(run_name + "_off", {"timeline": timeline, "off": "time_dilation_enabled"})
	if results["a"].has("timed_out") or fixed["a"].has("timed_out"):
		_check(false, "dilation ramp: every machine finished")
		return
	var a: Dictionary = results["a"]
	var f: Dictionary = fixed["a"]
	print("        with dilation: %d missed inputs, %d resyncs, lowest margin %d" % [int(a["missed_inputs"]) - int(a["missed_inputs_start"]), int(a["stats"]["resyncs"]), int(a["stats"]["margin_lowest"])])
	print("        fixed lead:    %d missed inputs, %d resyncs, lowest margin %d" % [int(f["missed_inputs"]) - int(f["missed_inputs_start"]), int(f["stats"]["resyncs"]), int(f["stats"]["margin_lowest"])])
	_check(int(a["stats"]["resyncs"]) <= int(f["stats"]["resyncs"]), "dilation ramp: no more jumps than a fixed lead")
	_check(int(a["missed_inputs"]) - int(a["missed_inputs_start"]) <= int(f["missed_inputs"]) - int(f["missed_inputs_start"]) + 3, "dilation ramp: no more missed inputs than a fixed lead")
	# Ping drops after the client settled on a large lead, so it ends up further ahead than it needs to be.
	var dropping := "0:60,5:60,7:5,16:5"
	var down_on := await _dilation_results(run_name + "_down_on", {"timeline": dropping})
	var down_off := await _dilation_results(run_name + "_down_off", {"timeline": dropping, "off": "time_dilation_enabled"})
	if down_on["a"].has("timed_out") or down_off["a"].has("timed_out"):
		_check(false, "dilation ramp: every machine finished")
		return
	print("        ping dropping, inputs arrive early by: %.1f ticks with dilation, %.1f with a fixed lead" % [_margin_average(down_on["a"]), _margin_average(down_off["a"])])
	_check(_margin_average(down_on["a"]) < _margin_average(down_off["a"]), "dilation ramp: when ping drops, it stops wasting the extra lead")


func _test_prediction_off(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 11, "latency": 50},
		"a": {"role": "client", "seconds": 10, "latency": 50, "mode": "strafe", "off": "prediction_enabled"},
	}, _port)
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	if server.has("timed_out") or a.has("timed_out"):
		_check(false, "prediction off: every machine finished")
		return
	var own := NetRun.own_entity(a)
	_check(int(own["role"]) == NetworkEntity.Role.LOCAL_UNPREDICTED, "prediction off: your own pawn isn't predicted")
	var truth: Dictionary = server["positions"].get(str(int(own["id"])), {})
	var zs: Array = truth.values().map(func(p: Array) -> float: return float(p[2]))
	_check(zs.size() > 100 and absf(zs.max() - zs.min()) > 3.0, "prediction off: the server still moves it from your inputs")
	var view := NetRun.view_error(a, server, int(own["id"]))
	print("        your own pawn is drawn %.1f ticks behind your own tick, %.2f cm from where it really was then" % [view["behind_ticks"], 100.0 * view["average"]])
	_check(view["ticks"] > 100 and view["average"] < 0.05, "prediction off: you see where it really was")
	_check(view["behind_ticks"] > 8.0, "prediction off: and what you do shows up late, which is the point")
	_check(int(a["stats"]["corrections"]) == 0, "prediction off: nothing needs correcting")


func _test_reconciliation_off(run_name: String) -> void:
	for smoothing_off: bool in [false, true]:
		_port += 1
		var client: Dictionary = {"role": "client", "seconds": 8, "latency": 50, "mode": "idle"}
		if smoothing_off:
			client["off"] = "correction_smoothing_enabled"
		var with_correction := await NetRun.run(self, run_name + ("_smoothing_off" if smoothing_off else "_smoothing_on"), {
			"server": {"role": "server", "seconds": 9, "latency": 50, "shove-at": 400},
			"a": client,
		}, _port)
		if with_correction["a"].has("timed_out"):
			_check(false, "correction smoothing: every machine finished")
			return
		var seen := int(NetRun.own_entity(with_correction["a"]).get("corrections_seen", -1))
		if smoothing_off:
			_check(seen == 0 and int(with_correction["a"]["stats"]["corrections"]) >= 1, "correction smoothing: off, corrections happen but the model isn't told")
		else:
			_check(seen >= 1, "correction smoothing: on, the model hides the jump")
	_port += 1
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 9, "latency": 50, "shove-at": 400},
		"a": {"role": "client", "seconds": 8, "latency": 50, "mode": "idle", "off": "reconciliation_enabled"},
	}, _port)
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	if server.has("timed_out") or a.has("timed_out"):
		_check(false, "reconciliation off: every machine finished")
		return
	_check(int(a["stats"]["corrections"]) == 0, "reconciliation off: the client never corrects itself")
	var own := NetRun.own_entity(a)
	var on_server := NetRun.summary_of(server, int(own["id"]))
	var apart := Vector2(float(own["x"]) - float(on_server["x"]), float(own["z"]) - float(on_server["z"])).length()
	print("        client and server ended %.2f m apart" % apart)
	_check(apart > 1.5, "reconciliation off: so client and server stay apart after a shove")


func _test_interpolation_off(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 11, "latency": 40},
		"mover": {"role": "client", "seconds": 10, "latency": 40, "mode": "strafe"},
		"watcher": {"role": "client", "seconds": 10, "latency": 40, "mode": "idle", "off": "interpolation_enabled"},
	}, _port)
	var server: Dictionary = results["server"]
	var mover: Dictionary = results["mover"]
	var watcher: Dictionary = results["watcher"]
	if server.has("timed_out") or mover.has("timed_out") or watcher.has("timed_out"):
		_check(false, "interpolation off: every machine finished")
		return
	var view := NetRun.view_error(watcher, server, int(NetRun.own_entity(mover)["id"]))
	print("        drawn %.1f ticks behind, largest step %.1f cm in one tick" % [view["behind_ticks"], 100.0 * view["largest_step"]])
	_check(view["behind_ticks"] < 12.0, "interpolation off: remote pawns are drawn less far in the past")
	_check(view["largest_step"] > 0.13, "interpolation off: and they visibly jump from snapshot to snapshot")


func _test_live_switches(run_name: String) -> void:
	var results := await NetRun.run(self, run_name + "_allowed", {
		"server": {"role": "server", "seconds": 10, "allow-debug": 1},
		"a": {"role": "client", "seconds": 9, "mode": "strafe", "switch": "4:lag_compensation_enabled:0"},
		"b": {"role": "client", "seconds": 9, "mode": "strafe", "switch": "5:prediction_enabled:0"},
	}, _port)
	if results["server"].has("timed_out") or results["a"].has("timed_out") or results["b"].has("timed_out"):
		_check(false, "live switches: every machine finished")
		return
	_check(not results["server"]["features"]["lag_compensation_enabled"], "live switches: with permission, a client can switch a server feature for testing")
	_check(not results["a"]["features"]["lag_compensation_enabled"] and not results["b"]["features"]["lag_compensation_enabled"], "live switches: and every client's panel shows it")
	_check(int(NetRun.own_entity(results["b"])["role"]) == NetworkEntity.Role.LOCAL_UNPREDICTED, "live switches: prediction can be turned off while running")
	_port += 1
	var refused := await NetRun.run(self, run_name + "_refused", {
		"server": {"role": "server", "seconds": 7},
		"a": {"role": "client", "seconds": 6, "mode": "idle", "switch": "3:lag_compensation_enabled:0"},
	}, _port)
	if refused["server"].has("timed_out"):
		_check(false, "live switches: the server finished")
		return
	_check(refused["server"]["features"]["lag_compensation_enabled"], "live switches: without permission, the server ignores it")
	_check(refused["a"]["features"]["lag_compensation_enabled"], "live switches: and the client's panel doesn't claim otherwise")
	_check(int(refused["server"]["stats"]["bad_packets"]) >= 1, "live switches: and counts it as a bad packet")
	_port += 1
	var to_predicted := await NetRun.run(self, run_name + "_predicted", {
		"server": {"role": "server", "seconds": 10, "allow-debug": 1},
		"mover": {"role": "client", "seconds": 9, "mode": "strafe"},
		"watcher": {"role": "client", "seconds": 9, "mode": "idle", "switch": "4:default_predicted:1"},
	}, _port)
	if to_predicted["watcher"].has("timed_out") or to_predicted["mover"].has("timed_out"):
		_check(false, "live switches: every machine finished")
		return
	var mover_id := int(NetRun.own_entity(to_predicted["mover"])["id"])
	_check(int(NetRun.summary_of(to_predicted["watcher"], mover_id)["role"]) == NetworkEntity.Role.REMOTE_PREDICTED, "live switches: other pawns can start being predicted while running")


## On a jittery connection, drawing further back should mean running out of snapshots less often.
func _test_adaptive_interpolation(run_name: String) -> void:
	var totals := {}
	for adaptive: bool in [true, false]:
		_port += 1
		var watcher: Dictionary = {"role": "client", "seconds": 11, "latency": 20, "jitter": 150, "mode": "idle", "conditions-seed": 31}
		if not adaptive:
			watcher["off"] = "adaptive_interpolation_enabled"
		var results := await NetRun.run(self, run_name + ("_on" if adaptive else "_off"), {
			"server": {"role": "server", "seconds": 12, "latency": 20, "jitter": 150, "conditions-seed": 32},
			"mover": {"role": "client", "seconds": 11, "mode": "strafe"},
			"watcher": watcher,
		}, _port)
		if results["watcher"].has("timed_out") or results["mover"].has("timed_out"):
			_check(false, "adaptive interpolation: every machine finished")
			return
		var view := NetRun.view_error(results["watcher"], results["server"], int(NetRun.own_entity(results["mover"])["id"]))
		totals[adaptive] = {"behind": view["behind_ticks"], "late": int(results["watcher"]["stats"]["interpolation_underruns"])}
	print("        with 150 ms jitter: adaptive draws %.1f ticks behind and runs out %d times; fixed draws %.1f behind and runs out %d times" % [totals[true]["behind"], totals[true]["late"], totals[false]["behind"], totals[false]["late"]])
	_check(totals[true]["behind"] > totals[false]["behind"], "adaptive interpolation: on a jittery connection, it draws further back")
	_check(totals[true]["late"] < totals[false]["late"], "adaptive interpolation: and runs out of snapshots less often")


## The bench sets its whole ping from one side, through both of that client's fake networks.
func _test_bench_ping(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 13},
		"a": {"role": "client", "seconds": 12, "mode": "strafe", "bench-ping": 120},
	}, _port)
	var a: Dictionary = results["a"]
	if a.has("timed_out"):
		_check(false, "bench ping: the client finished")
		return
	print("        bench ping 120: measured %.1f ms, lead %.1f ticks, %d resyncs, %d missed inputs" % [float(a["rtt_ms"]), float(a["lead_ticks"]), int(a["stats"]["resyncs"]), int(a["missed_inputs"]) - int(a["missed_inputs_start"])])
	_check(float(a["rtt_ms"]) > 110.0 and float(a["rtt_ms"]) < 165.0, "bench ping: a client sees the ping it set, from one side only")
	_check(int(a["stats"]["resyncs"]) == 0, "bench ping: it doesn't need to jump")
	_check(int(a["missed_inputs"]) - int(a["missed_inputs_start"]) <= 3, "bench ping: and it doesn't miss inputs")


## A machine freezes every few seconds. Inputs lost should be about what the freeze itself costs, not seconds' worth.
func _test_hitches(run_name: String) -> void:
	var client_hitch := await NetRun.run(self, run_name + "_client", {
		"server": {"role": "server", "seconds": 16, "walkers": 4},
		"a": {"role": "client", "seconds": 15, "mode": "strafe", "latency": 25, "hitch": "3:250"},
	}, _port)
	_port += 1
	var server_hitch := await NetRun.run(self, run_name + "_server", {
		"server": {"role": "server", "seconds": 16, "walkers": 4, "hitch": "3:250"},
		"a": {"role": "client", "seconds": 15, "mode": "strafe", "latency": 25},
	}, _port)
	if client_hitch["a"].has("timed_out") or server_hitch["a"].has("timed_out"):
		_check(false, "hitches: every machine finished")
		return
	var a: Dictionary = client_hitch["a"]
	var hitches := int(a["hitches"])
	var missed := (int(a["missed_inputs"]) - int(a["missed_inputs_start"])) / 4
	print("        client freezing 250 ms, %d times: %d inputs missed per pawn, %d jumps back" % [hitches, missed, int(a["stats"]["resyncs"])])
	_check(hitches >= 2, "hitches: the client really froze")
	_check(missed <= hitches * 30, "hitches: a client recovers from a freeze quickly, instead of missing inputs for seconds")
	var bad := int(server_hitch["server"]["stats"]["bad_packets"])
	print("        server freezing 250 ms, %d times: %d packets refused" % [int(server_hitch["server"]["hitches"]), bad])
	_check(int(server_hitch["server"]["hitches"]) >= 2, "hitches: the server really froze")
	_check(bad == 0, "hitches: real inputs aren't refused when they pile up during a server freeze")


## One pawn alone on hills, walking nav paths: slopes with nothing to bump into.
func _test_terrain(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 26, "terrain": 1},
		"a": {"role": "client", "seconds": 25, "terrain": 1, "mode": "walk", "bench-ping": 100},
	}, _port)
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	if server.has("timed_out") or a.has("timed_out"):
		_check(false, "terrain: every machine finished")
		return
	var own := NetRun.own_entity(a)
	var error := NetRun.prediction_error(a, server, int(own["id"]))
	var stats: Dictionary = a["stats"]
	var climbed := _height_range(server, int(own["id"]))
	print("        walked %.0f m on %d paths (%d failed, %d stuck), climbing through %.1f m of height" % [float(own["walked"]), int(own["paths"]), int(own["path_failures"]), int(own["stuck"]), climbed])
	print("        own pawn on slopes against the server: average %.2f cm, worst %.2f cm over %d ticks; %d corrections, worst %.2f m" % [100.0 * error["average"], 100.0 * error["worst"], error["ticks"], int(stats["corrections"]), float(stats["correction_worst"])])
	_check(float(own["walked"]) > 30.0 and int(own["paths"]) >= 1, "terrain: the pawn walks nav paths")
	_check(climbed > 0.5, "terrain: and it really went up and down hills")
	_check(error["average"] < 0.02, "terrain: prediction matches the server on slopes within 2 cm on average")
	_check(int(stats["resyncs"]) == 0, "terrain: the clock stays settled")


func _height_range(machine: Dictionary, entity_id: int) -> float:
	var path: Dictionary = machine["positions"].get(str(entity_id), {})
	var heights: Array = path.values().map(func(p: Array) -> float: return float(p[1]))
	return 0.0 if heights.is_empty() else float(heights.max()) - float(heights.min())


func _test_worst_case(run_name: String) -> void:
	var results := await NetRun.run(self, run_name, {
		"server": {"role": "server", "seconds": 21},
		"a": {"role": "client", "seconds": 20, "mode": "seek", "preset": "worst", "conditions-seed": 11},
		"b": {"role": "client", "seconds": 20, "mode": "seek", "preset": "mobile", "conditions-seed": 12},
	}, _port)
	var server: Dictionary = results["server"]
	var a: Dictionary = results["a"]
	var b: Dictionary = results["b"]
	if server.has("timed_out") or a.has("timed_out") or b.has("timed_out"):
		_check(false, "worst case: every machine finished")
		return
	print("        worst case client: %d bursts, %d spikes, %d resyncs, %d of its inputs missed, lowest margin %d, speed %.3f to %.3f" % [int(a["bursts"]), int(a["spikes"]), int(a["stats"]["resyncs"]), int(a["missed_inputs"]), int(a["stats"]["margin_lowest"]), float(a["stats"]["speed_lowest"]), float(a["stats"]["speed_highest"])])
	_check(a["joined"] and b["joined"], "worst case: both clients still join")
	_check(int(a["bursts"]) + int(a["spikes"]) > 0, "worst case: it really was bad")
	var truth: Dictionary = server["positions"].get(str(int(NetRun.own_entity(a).get("id", -1))), {})
	var xs: Array = truth.values().map(func(p: Array) -> float: return float(p[0]))
	_check(xs.size() > 100 and absf(xs.max() - xs.min()) > 1.0, "worst case: the pawn still moves from its inputs")
	var own := NetRun.own_entity(a)
	var on_server := NetRun.summary_of(server, int(own["id"]))
	_check(not on_server.is_empty(), "worst case: and the client stayed connected")


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
