## Written by Claude (claude-opus-5-5), 2026-11-07: quick headless checks of NetworkSession that need no real connection. From the audit of
## 6df1464: world messages don't outlive a session, an entity whose only state is save_state() data still goes in snapshots, and the
## named actions are part of the content hash and frozen while online. net_selftest covers real connections.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/netcode/tests/net_session_selftest.tscn"
extends Node

var _failures := 0


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
	_test_unusable_inputs_dont_count()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


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
	var error := session.host(47000 + randi() % 2000)
	_check(error == OK, "(hosting, with nobody connected)")
	var before: int = session.stats["snapshots_encoded"]
	for i in 12:
		await get_tree().physics_frame
	_check(session.stats["snapshots_encoded"] == before and not session._has_welcomed_peer(), "a host with no client encodes no snapshots")
	session._peers[999] = {"welcomed": true, "margins": [], "acknowledged_snapshot": -1}
	_check(session._has_welcomed_peer(), "(and one welcomed client is enough to start)")
	session._peers.erase(999)
	session.leave()


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
	session._peers[peer] = {"welcomed": true, "margins": [], "acknowledged_snapshot": -1}
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
	_check(session.stats["rejected_inputs"] == rejected + 1 and session._peers[peer]["margins"].is_empty(), "an empty input packet is rejected, and its timing doesn't count")
	session._on_input(peer, packet.call(tick + 1000000, [[1]]), tick)
	_check(session.stats["rejected_inputs"] == rejected + 2 and session._peers[peer]["margins"].is_empty(), "so is one claiming a tick beyond any history")
	session._on_input(peer, packet.call(tick + 2, [[1, 2, 3]]), tick)
	_check(session.stats["bad_packets"] == bad + 1 and session._peers[peer]["margins"].is_empty(), "and one with the wrong number of fields is a bad packet")
	session._on_input(peer, packet.call(tick + 2, [[1]]), tick)
	_check(session._peers[peer]["margins"].size() == 1, "a good one counts towards the timing")
	session._peers.erase(peer)
	session._entities.erase(entity_id)
	session.leave()
	root.free()


func _test_actions_in_the_content_hash() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	InputActions.use_list([&"jump", &"sprint"])
	session._hash_is_cached = false
	var first := session.content_hash()
	InputActions.use_list([&"sprint", &"jump"])
	session._hash_is_cached = false
	var swapped := session.content_hash()
	_check(first != swapped, "the named actions, in bit order, are part of the content hash")
	InputActions.reset()
	session._hash_is_cached = false


func _test_actions_frozen_online() -> void:
	var session: NetworkSessionSingleton = NetworkSession
	InputActions.use_list([&"jump"])
	print("  (a warning about 'made_up_online' is expected next)")
	session._mode = NetworkSessionSingleton.Mode.SERVER # pretend to be online
	_check(InputActions.mask_of(&"made_up_online") == 0, "online, an action that isn't listed gets no bit")
	_check(InputActions.mask_of(&"jump") == 1, "while listed ones work as before")
	session._mode = NetworkSessionSingleton.Mode.OFFLINE
	print("  (and one about 'made_up_offline')")
	_check(InputActions.mask_of(&"made_up_offline") == 2, "offline, it's still added at the end, with a warning")
	InputActions.reset()


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
