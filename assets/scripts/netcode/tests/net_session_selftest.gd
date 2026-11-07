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
