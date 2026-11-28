## Written by Claude (claude-opus-5-5), 2026-11-07: quick headless checks of NetworkSession that need no real connection. From the audit of
## 6df1464: world messages don't outlive a session, an entity whose only state is save_state() data still goes in snapshots, and the
## named actions are part of the content hash and frozen while online. net_selftest covers real connections.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/netcode/tests/net_session_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const TestActions := preload("res://assets/scripts/controllers/tests/input_actions_for_tests.gd")


## An entity whose only rollback state is what save_state returns: no state list at all.
class CustomOnly extends Node:
	var counter := 0

	func save_state() -> Dictionary:
		return {"counter": counter}

	func load_state(saved: Dictionary) -> void:
		counter = saved.get("counter", 0)

	func _tick_simulate(_dt: float, _tick: int) -> void:
		counter += 1


func _ready() -> void:
	print("--- Network session self-test (no connections) ---")
	_test_world_messages_end_with_the_session()
	await _test_custom_only_entity_is_in_snapshots()
	_test_actions_in_the_content_hash()
	_test_actions_frozen_online()
	await _test_sync_only_entity_is_in_snapshots() # Claude 2026-11-16 (networking T1.0)
	await _test_no_snapshots_without_clients()
	_test_acknowledgements() # Claude 2026-11-16
	await _test_delta_round_trip() # Claude 2026-11-16 (audit double-check)
	_test_cut_into_parts() # Claude 2026-11-16 (audit double-check)
	_test_unusable_inputs_dont_count()
	_test_snapshot_lists_must_fit() # Claude 2026-11-16 (networking N4)
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


# Claude 2026-11-16 (wider audit): a port from this run's own range (NetRun.first_port), one further each time. It was a random port,
# which another program, or another test run, might already have.
var _port := NetRun.first_port() + 40
func _next_port() -> int:
	_port += 1
	return _port


func _test_world_messages_end_with_the_session() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	session._mode = NetworkSessionSingleton.Mode.CLIENT # pretend, so the message is accepted the way a client accepts it
	var message := PackedByteArray([NetPackets.Type.WORLD_MESSAGE, 1, 2, 3, 4, 9])
	session._on_world_message(1, message)
	_check(session._world_inbox.size() == 1, "(a world message from the server is waiting)")
	session.leave()
	_check(session._world_inbox.is_empty(), "leaving the session throws away world messages still waiting")
	_check(not session.is_client() and not session.is_server(), "(and the session is offline again)")


func _test_custom_only_entity_is_in_snapshots() -> void:
	var root := CustomOnly.new()
	root.name = "CustomOnly"
	var state := TickStateComponent.new()
	state.name = "TickState"
	root.add_child(state)
	var entity := NetworkEntity.new()
	entity.name = "NetworkEntity"
	root.add_child(entity)
	add_child(root)
	for i in 4:
		await get_tree().physics_frame
	var recorded: int = TickDriver.tick - 1
	_check(state.has_state(recorded) and state.get_state_values(recorded).is_empty(), "(it recorded a tick, with an empty state list)")
	_check(state.get_custom_values(recorded).size() == 1, "(and one piece of save_state data)")
	_check(NetworkSession._is_in_snapshot(entity, recorded), "an entity whose only state is save_state data goes in snapshots")
	_check(not NetworkSession._is_in_snapshot(entity, TickDriver.tick + 100), "a tick it didn't record leaves it out, as for a paused entity")
	entity.is_replicated = false
	_check(not NetworkSession._is_in_snapshot(entity, recorded), "and an entity that isn't replicated is left out")
	root.free()


# Claude 2026-11-16 (networking T1.0): an entity whose only networked value is a sync property (a score, say). N3 in the networking assessment: it used to
# record nothing, so it never went into a snapshot.
class SyncOnly extends Node:
	var score := 0


func _test_sync_only_entity_is_in_snapshots() -> void:
	var root := SyncOnly.new()
	root.name = "SyncOnly"
	var state := TickStateComponent.new()
	state.name = "TickState"
	state.sync_properties = ["score"]
	root.add_child(state)
	var entity := NetworkEntity.new()
	entity.name = "NetworkEntity"
	root.add_child(entity)
	add_child(root)
	for i in 4:
		await get_tree().physics_frame
	var recorded: int = TickDriver.tick - 1
	_check(state.has_state(recorded) and state.get_state_values(recorded).is_empty(), "an entity with only sync properties records its ticks, with an empty state list")
	_check(NetworkSession._is_in_snapshot(entity, recorded), "so it goes in snapshots, carrying its sync values")
	root.free()


# Claude 2026-11-16 (networking T1.0): N1: a host with nobody connected gathers and encodes nothing.
func _test_no_snapshots_without_clients() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	var error := session.host(_next_port())
	_check(error == OK, "(hosting, with nobody connected)")
	var before: int = session.stats["snapshots_encoded"]
	for i in 12:
		await get_tree().physics_frame
	_check(session.stats["snapshots_encoded"] == before and not session._has_welcomed_peer(), "a host with no client encodes no snapshots")
	session._peers[999] = session._new_peer(true)
	_check(session._has_welcomed_peer(), "(and one welcomed client is enough to start)")
	session._peers.erase(999)
	session.leave()


# Claude 2026-11-16 (per-part acknowledgements; began as the owner's question about a client with no pawn): a client says which parts of
# a snapshot it read in an ACK of its own. Every entity that was in a part it read gets that tick as its baseline for that client;
# entities in a part it didn't read keep theirs. An older tick never moves a baseline back, a tick from the future is ignored, and a
# broken ACK counts as a bad packet. The lag compensation number moves forward as before.
func _test_acknowledgements() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	_check(session.host(_next_port()) == OK, "(hosting, for acknowledgements)")
	var now: int = TickDriver.tick
	session._peers[998] = session._new_peer(true)
	session._peers[998].sent_parts = {now - 4: [PackedInt32Array([7, 8]), PackedInt32Array([9])], now - 10: [PackedInt32Array([7, 8, 9])]}
	# One tick's entry: the tick, its part count, a bit per part read.
	var ack := func(tick: int, part_count: int, read_bits: int) -> PackedByteArray:
		var buffer := NetPackets.new_buffer()
		buffer.put_u8(NetPackets.Type.ACK)
		buffer.put_u8(1)
		buffer.put_u32(tick)
		buffer.put_u8(part_count)
		buffer.put_u8(read_bits)
		return buffer.data_array
	session._on_ack(998, ack.call(now - 4, 2, 0b01))
	var baselines: Dictionary = session._peers[998].baselines
	_check(baselines.get(7) == now - 4 and baselines.get(8) == now - 4 and not baselines.has(9), "an ACK of part 0 gives that part's entities that tick as their baseline, and not the others'")
	_check(session._peers[998].acknowledged_snapshot == now - 4, "and counts for lag compensation")
	session._on_ack(998, ack.call(now - 10, 1, 0b1))
	_check(baselines.get(7) == now - 4 and baselines.get(9) == now - 10 and session._peers[998].acknowledged_snapshot == now - 4,
		"an older tick fills in what had none, never moves one back, and doesn't move lag compensation back")
	session._on_ack(998, ack.call(now + 500, 1, 0b1))
	_check(session._peers[998].acknowledged_snapshot == now - 4, "a tick from the future is ignored")
	var bad_before: int = session.stats["bad_packets"]
	session._on_ack(998, PackedByteArray([NetPackets.Type.ACK, 1, 0, 0]))
	_check(session.stats["bad_packets"] == bad_before + 1, "a broken one counts as a bad packet")
	# Claude 2026-11-16 (audit double-check): the limits on one ACK packet.
	session._peers[998].sent_parts[now - 2] = [PackedInt32Array([20]), PackedInt32Array([21])]
	var twice := NetPackets.new_buffer()
	twice.put_u8(NetPackets.Type.ACK)
	twice.put_u8(2)
	for read_bits: int in [0b01, 0b10]: # the same tick two times, a different part each
		twice.put_u32(now - 2)
		twice.put_u8(2)
		twice.put_u8(read_bits)
	session._on_ack(998, twice.data_array)
	_check(baselines.get(20) == now - 2 and not baselines.has(21), "a tick named twice in one ACK is read once")
	var too_many := NetPackets.new_buffer()
	too_many.put_u8(NetPackets.Type.ACK)
	too_many.put_u8(NetworkSessionSingleton.MAX_ACK_ENTRIES + 1)
	for i in NetworkSessionSingleton.MAX_ACK_ENTRIES + 1:
		too_many.put_u32(now - 2)
		too_many.put_u8(2)
		too_many.put_u8(0b10)
	bad_before = session.stats["bad_packets"]
	session._on_ack(998, too_many.data_array)
	_check(session.stats["bad_packets"] == bad_before + 1 and not baselines.has(21), "an ACK naming more ticks than a client ever sends is refused whole")
	# Claude 2026-11-16 (wider audit): the timing a client is told. One that stopped sending inputs is told nothing, not its last margins.
	var sender := session._new_peer(true)
	sender.margins = [4, 2, 3]
	sender.newest_input = now + 2
	_check(session._margins_to_report(sender, now)[0] == 2, "timing report: a client sending inputs is told its worst recent margin")
	_check(session._margins_to_report(sender, now + 200) == PackedInt32Array([NetworkSessionSingleton.NO_MARGIN, NetworkSessionSingleton.NO_MARGIN]) and sender.margins.is_empty(),
		"timing report: one whose inputs stopped is told nothing, and its old margins are dropped")
	# The client side: parts read are gathered into one ACK a tick.
	session._acks_to_send.clear()
	session._note_part_read(300, 0, 10)
	session._note_part_read(300, 9, 10)
	var entry: NetworkSessionSingleton.PartsRead = session._acks_to_send.get(300)
	_check(entry != null and entry.part_count == 10 and entry.bits == PackedByteArray([1, 2]), "a client notes each part it read as a bit (%s)" % (str(entry.bits) if entry else "none"))
	session._acks_to_send.clear()
	session._peers.erase(998)
	session.leave()


# Claude 2026-11-16 (audit double-check): the delta encoder and decoder, checked directly (before, only whole networked games used
# them). An entity with 33 values, so its changes need two masks of 30: a change in entry 29 is the first mask's last bit, entry 30
# the second mask's first. v30 is a Vector3, to show a changed value keeps its own entry's encoding.
class ManyValues extends Node:
	var v00 := 0
	var v01 := 0
	var v02 := 0
	var v03 := 0
	var v04 := 0
	var v05 := 0
	var v06 := 0
	var v07 := 0
	var v08 := 0
	var v09 := 0
	var v10 := 0
	var v11 := 0
	var v12 := 0
	var v13 := 0
	var v14 := 0
	var v15 := 0
	var v16 := 0
	var v17 := 0
	var v18 := 0
	var v19 := 0
	var v20 := 0
	var v21 := 0
	var v22 := 0
	var v23 := 0
	var v24 := 0
	var v25 := 0
	var v26 := 0
	var v27 := 0
	var v28 := 0
	var v29 := 0
	var v31 := 0
	var v32 := 0
	var v30 := Vector3.ZERO


func _test_delta_round_trip() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	var root := ManyValues.new()
	root.name = "ManyValues"
	var state := TickStateComponent.new()
	state.name = "TickState"
	var names: Array[String] = []
	for i in 33:
		names.append("v%02d" % i)
	state.state_properties = names
	root.add_child(state)
	var entity := NetworkEntity.new()
	entity.name = "NetworkEntity"
	root.add_child(entity)
	add_child(root)
	entity.entity_id = 9003
	for i in 3:
		await get_tree().physics_frame
	var first: int = TickDriver.tick - 1
	root.v02 = 5
	root.v29 = 7
	root.v30 = Vector3(1, 2, 3)
	root.v32 = -4
	for i in 2:
		await get_tree().physics_frame
	var second: int = TickDriver.tick - 1
	for i in 2:
		await get_tree().physics_frame
	var third: int = TickDriver.tick - 1
	_check(state.has_state(first) and state.has_state(second) and state.has_state(third) and state.get_state_values(first).size() == 33, "(delta: three ticks recorded, 33 values each)")

	# The server's side: the changes between two ticks, encoded and read back as a client reads a snapshot.
	var decode := func(bytes: PackedByteArray) -> Array:
		var parsed: Variant = session._codec.read_world(bytes, 0, 1) if session._codec != null else NetPackets.read_world(NetPackets.reader(bytes), 1)
		return parsed[0] if parsed is Array and parsed.size() == 1 else []
	var item: Array = decode.call(session._delta_entity_bytes(entity, second, first))
	_check(item.size() > 1 and item[0] & NetworkSessionSingleton.DELTA_ID_BIT and item[0] & ~NetworkSessionSingleton.DELTA_ID_BIT == 9003, "delta: the entity's id carries the delta bit")
	var delta: Array = item[1] if item.size() > 1 else []
	_check(delta.size() == 3 + 4 and delta[0] == second - first, "delta: ticks back, two masks, then the four changed values (%s)" % str(delta))
	_check(delta.size() > 2 and delta[1] == (1 << 2) | (1 << 29) and delta[2] == (1 << 0) | (1 << 2), "delta: entries 2 and 29 in the first mask, 30 and 32 in the second")

	# The client's side: with the baseline it kept, the full list comes back; without it, nothing.
	_check(session._rebuild_from_delta(entity, second, delta) == null, "delta: a client without the baseline can't rebuild it")
	session._keep_baseline(9003, first, state.get_state_values(first))
	var rebuilt: Variant = session._rebuild_from_delta(entity, second, delta)
	_check(rebuilt != null and rebuilt == state.get_state_values(second), "delta: with the baseline, the client rebuilds exactly what the server had")
	var unchanged: Array = decode.call(session._delta_entity_bytes(entity, third, second))
	session._keep_baseline(9003, second, state.get_state_values(second))
	_check(unchanged.size() > 1 and unchanged[1].size() == 3 and session._rebuild_from_delta(entity, third, unchanged[1]) == state.get_state_values(third),
		"delta: nothing changed is ticks back and two empty masks, and rebuilds as the baseline")

	# A delta that doesn't fit is refused, not half applied.
	_check(session._rebuild_from_delta(entity, second, delta.slice(0, delta.size() - 1)) == null, "delta: a value missing: refused")
	_check(session._rebuild_from_delta(entity, second, delta + [1]) == null, "delta: a value too many: refused")
	_check(session._rebuild_from_delta(entity, second, [second - first, 0]) == null, "delta: a mask missing: refused")
	_check(session._rebuild_from_delta(entity, second, [second - first, "x", 0]) == null, "delta: a mask that isn't a number: refused")
	_check(session._rebuild_from_delta(entity, second, [second - first, 0, 1 << 3, 9]) == null, "delta: a change to an entry past the end of the list: refused")
	_check(session._delta_entity_bytes(entity, second, first - 5000).is_empty(), "delta: a baseline tick the server no longer has: sent in full instead")
	session._baselines.erase(9003)
	root.free()


# Claude 2026-11-16 (audit double-check): a snapshot's entities cut into parts: full parts in order, an entity bigger than a part alone.
func _test_cut_into_parts() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	var small := PackedByteArray()
	small.resize(500)
	var big := PackedByteArray()
	big.resize(NetworkSessionSingleton.SNAPSHOT_PART_BYTES + 900)
	var chunks: Array[PackedByteArray] = [small, small, small, big, small]
	var parts := session._cut_into_parts(chunks, PackedInt32Array([1, 2, 3, 4, 5]))
	var ids: Array = []
	for part in parts:
		ids.append(Array(part.ids))
	_check(ids == [[1, 2], [3], [4], [5]], "parts: two of 500 bytes fit a part, and an entity bigger than a part goes alone (%s)" % str(ids))
	_check(parts[0].bytes.size() == 1000 and parts[2].bytes.size() == big.size(), "parts: each part holds its entities' bytes")
	var none: Array[PackedByteArray] = []
	_check(session._cut_into_parts(none, PackedInt32Array()).size() == 1, "parts: no entities is still one part, so the snapshot arrives")


# Claude 2026-11-16 (networking T1.0): N2: input that can't be used doesn't count towards a client's timing (time dilation): an empty packet, one claiming a
# newest tick beyond any history, and one with the wrong number of fields. A good one does count.
class InputOnly extends Node:
	var wanted := 0


func _test_unusable_inputs_dont_count() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	var root := InputOnly.new()
	root.name = "InputOnly"
	var state := TickStateComponent.new()
	state.name = "TickState"
	state.input_properties = ["wanted"]
	root.add_child(state)
	var entity := NetworkEntity.new()
	entity.name = "NetworkEntity"
	root.add_child(entity)
	add_child(root)
	var peer := 77
	var entity_id := 9001
	entity.configure(entity_id, "test", peer, NetworkEntity.Role.AUTHORITY, false, session)
	session._entities[entity_id] = entity
	session._mode = NetworkSessionSingleton.Mode.SERVER # pretend, so the packets are read the way a server reads them
	session._peers[peer] = session._new_peer(true)
	var tick: int = TickDriver.tick
	var encodings: Array = state.get_input_encodings()
	var packet := func(newest: int, lists: Array) -> PackedByteArray:
		var buffer := NetPackets.new_buffer()
		buffer.put_u8(NetPackets.Type.INPUT)
		buffer.put_u32(entity_id)
		buffer.put_u32(newest)
		buffer.put_32(-1)
		buffer.put_u8(lists.size())
		for values: Array in lists:
			NetPackets.write_list(buffer, values, encodings if values.size() == encodings.size() else [])
		return buffer.data_array
	var rejected: int = session.stats["rejected_inputs"]
	var bad: int = session.stats["bad_packets"]
	session._on_input(peer, packet.call(tick + 2, []), tick)
	_check(session.stats["rejected_inputs"] == rejected + 1 and session._peers[peer].margins.is_empty(), "an empty input packet is rejected, and its timing doesn't count")
	session._on_input(peer, packet.call(tick + 1000000, [[1]]), tick)
	_check(session.stats["rejected_inputs"] == rejected + 2 and session._peers[peer].margins.is_empty(), "so is one claiming a tick beyond any history")
	session._on_input(peer, packet.call(tick + 2, [[1, 2, 3]]), tick)
	_check(session.stats["bad_packets"] == bad + 1 and session._peers[peer].margins.is_empty(), "and one with the wrong number of fields is a bad packet")
	session._on_input(peer, packet.call(tick + 2, [[1]]), tick)
	_check(session._peers[peer].margins.size() == 1, "a good one counts towards the timing")
	session._peers.erase(peer)
	session._entities.erase(entity_id)
	session.leave()
	root.free()


# Claude 2026-11-16 (networking N4): a snapshot whose lists for an entity have the wrong sizes is refused, counted and warned about,
# rather than read as empty. Empty lists are fine (nothing that tick), and the right sizes pass.
func _test_snapshot_lists_must_fit() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	var root := InputOnly.new()
	root.name = "SchemaCheck"
	var state := TickStateComponent.new()
	state.name = "TickState"
	state.state_properties = ["wanted"]
	root.add_child(state)
	var entity := NetworkEntity.new()
	entity.name = "NetworkEntity"
	root.add_child(entity)
	add_child(root)
	entity.configure(9002, "schema_test", 1, NetworkEntity.Role.REMOTE_FOLLOWING, false, session)
	_check(entity.state.get_list_sizes() == PackedInt32Array([1, 0, 0, 0]), "get_list_sizes gives state, sync, input and custom (%s)" % str(entity.state.get_list_sizes()))
	var mismatches: int = session.stats["schema_mismatches"]
	_check(session._snapshot_lists_fit(entity, [9002, [3], [], [], []]), "lists of the declared sizes fit")
	_check(session._snapshot_lists_fit(entity, [9002, [], [], [], []]), "and so do empty ones (nothing that tick)")
	_check(session.stats["schema_mismatches"] == mismatches, "neither counts as a mismatch")
	_check(not session._snapshot_lists_fit(entity, [9002, [3, 4], [], [], []]), "two state values where one is declared: refused")
	_check(not session._snapshot_lists_fit(entity, [9002, [3], [], [7], []]), "an input value where none is declared: refused")
	_check(session.stats["schema_mismatches"] == mismatches + 2, "each counted in stats.schema_mismatches")
	_check(session._schema_warned.has("schema_test"), "and warned about, once for the entity type")
	session.leave()
	_check(not session._schema_warned.has("schema_test"), "a new session warns afresh")
	root.free()


func _test_actions_in_the_content_hash() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	TestActions.use_list([&"jump", &"sprint"])
	session._hash_is_cached = false
	var first := session.content_hash()
	TestActions.use_list([&"sprint", &"jump"])
	session._hash_is_cached = false
	var swapped := session.content_hash()
	_check(first != swapped, "the named actions, in bit order, are part of the content hash")
	TestActions.reset()
	session._hash_is_cached = false


func _test_actions_frozen_online() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	TestActions.use_list([&"jump"])
	print("  (a warning about 'made_up_online' is expected next)")
	session._mode = NetworkSessionSingleton.Mode.SERVER # pretend to be online
	_check(InputActions.mask_of(&"made_up_online") == 0, "online, an action that isn't listed gets no bit")
	_check(InputActions.mask_of(&"jump") == 1, "while listed ones work as before")
	session._mode = NetworkSessionSingleton.Mode.OFFLINE
	print("  (and one about 'made_up_offline')")
	_check(InputActions.mask_of(&"made_up_offline") == 2, "offline, it's still added at the end, with a warning")
	TestActions.reset()
