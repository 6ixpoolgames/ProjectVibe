## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for the tier -1 Pawn and GroundMovement, offline.
## Claude 2026-11-07: GroundMovement is gone; the same checks now run through the Walk, Sprint and Jump abilities and the pawn's stats.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/pawn/tests/pawn_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"


func _ready() -> void:
	# Claude 2026-11-09 (scaling spec step 6): these checks count exact ticks at the reference rate, 60 a second, so they pin it, even
	# in a run at another rate (-- --tick-rate=30). tick_rate_selftest checks that converted settings last the same time at 30.
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- Pawn self-test ---")
	await _test_on_flat_ground()
	await _test_running_and_stopping()
	await _test_jumping()
	await _test_holding_jump() # Claude 2026-11-07: named actions
	await _test_missing_input_fades() # Claude 2026-11-07
	await _test_on_slopes()
	await _test_rollback_is_exact()
	await _test_rollback_keeps_presses() # Claude 2026-11-07
	await _test_server_corrects_held_history() # Claude 2026-11-07, from the audit of 6df1464
	await _test_no_movement_module()
	_test_bad_input()
	await _test_source_rules()
	await _test_ai_with_no_ground()
	await _test_no_arms_by_default()
	await _test_visual_smoothing()
	await _test_resting() # Claude 2026-11-09
	await _test_skipping_still_moves() # Claude 2026-11-16
	await _measure_a_crowd()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_on_flat_ground() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.2, 0.0))
	await _ticks(30)
	_check(pawn.grounded, "a pawn falls and lands")
	_check(absf(pawn.position.y) < 0.02, "on the floor (%.3f m)" % pawn.position.y)
	_check(is_zero_approx(pawn.velocity.y), "and stops falling")
	_check(pawn.rotation == Vector3.ZERO, "and its body never rotates")
	pawn.free()
	floor_body.free()


func _test_running_and_stopping() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	# Claude 2026-11-07: the speeds come from the pawn's stats now, which Walk and Sprint read.
	var walk_speed := pawn.stat_manager.get_value(&"MoveSpeed")
	var sprint_speed := pawn.stat_manager.get_value(&"SprintSpeed")
	await _ticks(20)
	_drive(pawn, Vector3(1.0, 0.0, 0.0))
	await _ticks(1)
	_check(pawn.velocity.x > 0.0 and pawn.velocity.x < walk_speed, "it accelerates, not instantly (%.2f m/s after a tick)" % pawn.velocity.x)
	await _ticks(30)
	_check(is_equal_approx(pawn.velocity.x, walk_speed), "and reaches its speed (%.2f m/s)" % pawn.velocity.x)
	_check(absf(angle_difference(pawn.yaw, atan2(-1.0, 0.0))) < 0.01, "and turns to face where it's going")
	var before := pawn.position.x
	await _ticks(60)
	_check(absf(pawn.position.x - before - walk_speed) < 0.05, "one second moves it its speed in metres (%.2f m)" % (pawn.position.x - before))
	_drive(pawn, Vector3(1.0, 0.0, 0.0), true)
	await _ticks(60)
	_check(is_equal_approx(pawn.velocity.x, sprint_speed), "sprinting is faster (%.2f m/s)" % pawn.velocity.x)
	_drive(pawn, Vector3.ZERO)
	await _ticks(60)
	_check(is_zero_approx(pawn.velocity.x), "and with no input, it stops")
	_drive(pawn, Vector3(100.0, 0.0, 0.0))
	await _ticks(60)
	_check(is_equal_approx(pawn.velocity.x, walk_speed), "input longer than 1 doesn't go faster")
	pawn.free()
	floor_body.free()


func _test_jumping() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	await _ticks(20)
	_drive(pawn, Vector3.ZERO, false, true)
	await _ticks(1)
	_drive(pawn, Vector3.ZERO)
	_check(not pawn.grounded and pawn.velocity.y > 0.0, "a jump leaves the ground")
	var highest := 0.0
	for i in 120:
		await _ticks(1)
		highest = maxf(highest, pawn.position.y)
	_check(highest > 0.5, "and rises (%.2f m)" % highest)
	_check(pawn.grounded and absf(pawn.position.y) < 0.02, "and lands again")
	# Held in the air: nothing happens until it's on the ground.
	_drive(pawn, Vector3.ZERO, false, true)
	await _ticks(1)
	_drive(pawn, Vector3(1.0, 0.0, 0.0))
	await _ticks(5)
	var air_speed := pawn.velocity.x
	_check(air_speed < 30.0 * 0.3 * 6.0 / 60.0 + 0.01, "steering in the air is weaker (%.2f m/s)" % air_speed)
	pawn.free()
	floor_body.free()


## Claude 2026-11-07: a press is "held this tick, not last tick", so holding the key down jumps once, not every time it lands.
func _test_holding_jump() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	await _ticks(20)
	_drive(pawn, Vector3.ZERO, false, true)
	await _ticks(1)
	_check(pawn.velocity.y > 0.0, "holding jump: the first tick jumps")
	_check(pawn.controller_manager.is_action_held(&"jump") and pawn.controller_manager.previous_held_actions == pawn.controller_manager.held_actions, "and the pawn remembers it was held")
	var jumps := 1
	var was_grounded := false
	for i in 150: # still held the whole time
		await _ticks(1)
		if was_grounded and pawn.velocity.y > 0.0:
			jumps += 1
		was_grounded = pawn.grounded
	_check(jumps == 1 and pawn.grounded, "and landing with it still held doesn't jump again (%d jumps)" % jumps)
	_drive(pawn, Vector3.ZERO)
	await _ticks(1)
	_drive(pawn, Vector3.ZERO, false, true)
	await _ticks(1)
	_check(pawn.velocity.y > 0.0, "letting go and pressing again jumps")
	_check(not pawn.controller_manager.was_action_pressed(&"sprint") and not pawn.controller_manager.is_action_held(&"sprint"), "an action that isn't held reads as not held")
	pawn.free()
	floor_body.free()


## Claude 2026-11-07: on the server, when a client's input goes missing, the last one repeats, then its direction fades out.
func _test_missing_input_fades() -> void:
	var floor_body := _make_floor()
	# Claude 2026-11-07: like a client's pawn on the server: nothing here writes its input, so what the network left on it is what it uses.
	# Claude 2026-11-16 (pawn M4): the input lives on the ControllerManager now, so the pawn keeps one, with a player elsewhere: nobody here is in charge.
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	pawn.controller_manager.set_has_player(true)
	pawn.controller_manager.missing_input_hold_ticks = 3
	pawn.controller_manager.missing_input_fade_ticks = 6
	await _ticks(10)
	_drive(pawn, Vector3(1.0, 0.0, 0.0), true)
	await _ticks(1)
	# What NetworkEntity does each tick no input arrives. Calling it straight before a tick is the same.
	var lengths: Array[float] = []
	for i in 9:
		pawn.controller_manager._network_input_missing()
		await _ticks(1)
		lengths.append(pawn.controller_manager.move_input.length())
	_check(is_equal_approx(lengths[2], 1.0), "missing input: the last direction repeats in full for 3 ticks")
	_check(lengths[3] < 1.0 and lengths[3] > lengths[4], "then fades")
	_check(lengths[8] == 0.0, "and is gone after 6 more (%s)" % str(lengths))
	_check(pawn.controller_manager.is_action_held(&"sprint"), "held actions keep repeating, so a key still held isn't a new press later")
	_drive(pawn, Vector3(1.0, 0.0, 0.0), true)
	await _ticks(1)
	_check(pawn.controller_manager._missing_input_ticks == 0, "real input starts the count again") # Claude 2026-11-16 (pawn M4): the ControllerManager's now
	pawn.controller_manager._network_input_missing()
	await _ticks(1)
	_check(is_equal_approx(pawn.controller_manager.move_input.length(), 1.0), "so the next missing tick repeats in full")
	pawn.controller_manager.missing_input_hold_ticks = 0
	pawn.controller_manager.missing_input_fade_ticks = 0
	pawn.controller_manager._network_input_missing()
	await _ticks(1)
	_check(pawn.controller_manager.move_input == Vector3.ZERO, "with both set to 0, a missing input stops it at once")
	# Claude 2026-11-07: -1, the default, uses NetworkSession's settings.
	var session: Node = get_node("/root/NetworkSession")
	var saved_hold: int = session.missing_input_hold_ticks
	var saved_fade: int = session.missing_input_fade_ticks
	session.missing_input_hold_ticks = 1
	session.missing_input_fade_ticks = 0
	pawn.controller_manager.missing_input_hold_ticks = -1
	pawn.controller_manager.missing_input_fade_ticks = -1
	_drive(pawn, Vector3(1.0, 0.0, 0.0))
	await _ticks(1)
	pawn.controller_manager._network_input_missing()
	await _ticks(1)
	var after_one := pawn.controller_manager.move_input.length()
	pawn.controller_manager._network_input_missing()
	await _ticks(1)
	_check(is_equal_approx(after_one, 1.0) and pawn.controller_manager.move_input == Vector3.ZERO, "with -1, the pawn follows NetworkSession's settings")
	session.missing_input_hold_ticks = saved_hold
	session.missing_input_fade_ticks = saved_fade
	var plain := ControllerManager.new() # Claude 2026-11-16 (pawn M4): the settings are the ControllerManager's now
	_check(plain.missing_input_hold_ticks == -1 and plain.missing_input_fade_ticks == -1, "and -1 is the default, so the rule is set once per game")
	plain.free()
	pawn.free()
	floor_body.free()


func _test_on_slopes() -> void:
	var terrain := TerrainGenerator.new()
	terrain.name = "SlopeTerrain"
	terrain.chunk_radius = 1
	add_child(terrain)
	await get_tree().physics_frame
	var start := Vector3(5.0, terrain.height_at(5.0, 5.0) + 0.1, 5.0)
	var pawn := _make_pawn(start)
	await _ticks(20)
	_drive(pawn, Vector3(1.0, 0.0, 0.3).normalized())
	var worst := 0.0
	var climbed := 0.0
	var last_y := pawn.position.y
	for i in 600:
		await _ticks(1)
		worst = maxf(worst, absf(pawn.position.y - terrain.height_at(pawn.position.x, pawn.position.z)))
		climbed += absf(pawn.position.y - last_y)
		last_y = pawn.position.y
	var walked := Vector2(pawn.position.x - start.x, pawn.position.z - start.z).length()
	_check(walked > 30.0, "it walks across hills, past chunk edges (%.0f m, %.1f m up and down)" % [walked, climbed])
	_check(worst < 0.6, "and stays on the ground (worst %.2f m off)" % worst)
	pawn.free()
	terrain.free()


## The whole point of keeping movement in plain data. Load a past tick and run it again: it has to land in the same place.
func _test_rollback_is_exact() -> void:
	var terrain := TerrainGenerator.new()
	terrain.name = "RollbackTerrain"
	terrain.chunk_radius = 1
	add_child(terrain)
	await get_tree().physics_frame
	var pawn := _make_pawn(Vector3(5.0, terrain.height_at(5.0, 5.0) + 0.1, 5.0))
	# Claude 2026-11-16 (pawn spec 8.22): this checks physics replays. An AI-driven pawn offline would walk with the CrowdMover, which a
	# replay doesn't use; in a real game only clients replay, and only pawns that move by physics there.
	pawn.crowd_movement = false
	await _ticks(20)
	var pick := RandomNumberGenerator.new()
	pick.seed = 11
	var worst := 0.0
	var worst_y := 0.0
	var replays := 0
	for round_number in 6:
		for i in 25:
			var angle := pick.randf() * TAU
			_drive(pawn, Vector3(cos(angle), 0.0, sin(angle)), pick.randf() < 0.3, pick.randf() < 0.06)
			await _ticks(1)
		await get_tree().physics_frame # the signal comes before this frame's tick, so this lets the last tick finish
		var real_position := pawn.position
		var real_velocity := pawn.velocity
		var real_grounded := pawn.grounded
		var went_back: bool = TickDriver.rollback(TickDriver.tick - 20)
		replays += 1 if went_back else 0
		if went_back:
			worst = maxf(worst, pawn.position.distance_to(real_position))
			worst_y = maxf(worst_y, pawn.velocity.distance_to(real_velocity))
			if pawn.grounded != real_grounded:
				worst = 1000.0
	_check(replays == 6, "(rolled back and ran 20 ticks again %d times, on hills with jumps)" % replays)
	_check(worst < 0.0011, "a replay lands in the same place (worst %.4f m)" % worst)
	_check(worst_y < 0.011, "with the same velocity (worst %.4f m/s)" % worst_y)
	pawn.free()
	terrain.free()


## Claude 2026-11-07: going back to a tick where jump wasn't held, with the press on the very next tick. The replay has to see that
## press again. previous_held_actions isn't rollback state, so this checks it's read back from the saved input.
func _test_rollback_keeps_presses() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	await _ticks(20)
	_drive(pawn, Vector3.ZERO)
	await _ticks(1)
	await get_tree().physics_frame # so the tick above has surely finished
	var released_tick: int = TickDriver.tick
	_drive(pawn, Vector3.ZERO, false, true)
	for i in 8: # held from here on
		await _ticks(1)
	await get_tree().physics_frame
	var real_position := pawn.position
	var real_velocity := pawn.velocity
	_check(real_position.y > 0.05, "pressed after a release: it jumped (%.2f m up)" % real_position.y)
	var went_back: bool = TickDriver.rollback(released_tick)
	_check(went_back, "rolled back to the tick it was released")
	_check(pawn.position.distance_to(real_position) < 0.0011 and pawn.velocity.distance_to(real_velocity) < 0.011,
			"and the replay jumped again, the same way (%.4f m apart)" % pawn.position.distance_to(real_position))
	pawn.free()
	floor_body.free()


## Claude 2026-11-07, from the audit of 6df1464: the client held jump the whole time, but the server's correction says jump wasn't held
## on the tick it corrects (its copy of that press never arrived). The replay must then treat the next held tick as a press, as the
## server did. That only works because previous_held_actions is rollback state that corrections overwrite.
func _test_server_corrects_held_history() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	var tick_state: TickStateComponent = pawn.get_node("TickState")
	await _ticks(20)
	_drive(pawn, Vector3.ZERO, false, true) # held from here on: one jump, then standing with it held
	await _ticks(90)
	await get_tree().physics_frame
	_check(pawn.grounded and pawn.controller_manager.is_action_held(&"jump"), "(standing with jump held, after its one jump)")
	var corrected_tick: int = TickDriver.tick - 3
	var server_says := tick_state.get_state(corrected_tick)
	# Claude 2026-11-16 (pawn M4): keyed by its path, now that it lives on the ControllerManager.
	_check(int(server_says.get("ControllerManager:previous_held_actions", -1)) == InputActions.mask_of(&"jump"), "previous_held_actions is saved as rollback state")
	server_says["ControllerManager:previous_held_actions"] = 0
	tick_state.correct_state(corrected_tick, server_says)
	TickDriver.rollback(corrected_tick)
	_check(pawn.velocity.y > 0.0 or pawn.position.y > 0.05, "a correction saying jump wasn't held makes the replay jump, as the server did (%.2f m up)" % pawn.position.y)
	pawn.free()
	floor_body.free()


func _test_no_movement_module() -> void:
	var floor_body := _make_floor()
	# Claude 2026-11-07: abilities replaced the movement module, so it's the AbilityManager that's left out.
	var pawn := _make_pawn(Vector3(0.0, 0.01, 0.0), [&"AbilityManager"])
	_drive(pawn, Vector3(1.0, 0.0, 0.0))
	await _ticks(30)
	_check(absf(pawn.position.x) < 0.001, "with no AbilityManager, a pawn stands still")
	pawn.free()
	floor_body.free()


func _test_bad_input() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	add_child(pawn)
	# Claude 2026-11-07: held_actions replaces the two bools.
	var clean := pawn.controller_manager.sanitize_network_input({"move_input": Vector3(1000.0, 0.0, 0.0), "held_actions": "yes", "look_yaw": INF, "look_pitch": "up"})
	_check(is_equal_approx(clean["move_input"].length(), 1.0), "the server limits a client's direction")
	_check(clean["held_actions"] == 0, "and throws out wrong types")
	var made_up := pawn.controller_manager.sanitize_network_input({"held_actions": InputActions.mask_of(&"jump") | (1 << 62)})
	_check(made_up["held_actions"] == InputActions.mask_of(&"jump"), "and bits for actions that aren't listed")
	_check(clean["look_yaw"] == 0.0 and clean["look_pitch"] == 0.0, "and broken angles")
	var nan_move := pawn.controller_manager.sanitize_network_input({"move_input": Vector3(NAN, 0.0, 0.0)})
	_check(nan_move["move_input"] == Vector3.ZERO, "and broken directions")
	pawn.free()


# Claude 2026-11-07: _test_swapping_movement went with MovementModule. Choosing between locomotion abilities is tested in
# abilities/tests/ability_selftest.gd.


func _test_source_rules() -> void:
	# Claude 2026-11-19 (state store step 3): the pawn's PawnStreamingSource part, a default part, after the flag on the pawn (2026-11-16).
	var pawn := _make_pawn(Vector3.ZERO)
	# Claude 2026-11-16 (wider audit): and it's in the sources' group only while it might count, so the streamer's list stays short.
	_check(pawn.is_in_group(Pawn.GROUP), "every pawn is in the pawns group")
	var source := pawn.streaming_source
	_check(source != null and source.pawn == pawn and source.get_parent() == pawn, "the pawn has its streaming source part, which knows its pawn")
	_check(not pawn.is_keeping_world_loaded() and not source.is_in_group(StreamingSource.GROUP), "an AI pawn doesn't keep the world loaded by default, and its source isn't among the sources")
	source.keeps_world_loaded = true
	_check(pawn.is_keeping_world_loaded() and source.counts_on_this_machine() and source.is_in_group(StreamingSource.GROUP), "with keeps_world_loaded on, it does, and joins the sources")
	source.keeps_world_loaded = false
	_check(not pawn.is_keeping_world_loaded() and not source.is_in_group(StreamingSource.GROUP), "and stops when it goes off")
	pawn.controller_manager.set_has_player(true)
	_check(pawn.is_keeping_world_loaded() and source.is_in_group(StreamingSource.GROUP), "a pawn with a player does, and is among the sources")
	pawn.controller_manager.set_has_player(false)
	_check(not pawn.is_keeping_world_loaded() and not source.is_in_group(StreamingSource.GROUP), "until the player leaves")
	_check(source.load_distance == 320.0 and source.nav_distance == 128.0 and source.global_position == pawn.global_position,
		"at the pawn, with the game's distances (%.0f, %.0f)" % [source.load_distance, source.nav_distance])
	source.load_distance = 5.0
	_check(source.load_distance == 320.0, "its own distance setting is ignored for the game's")
	pawn.free()


func _test_ai_with_no_ground() -> void:
	var terrain := TerrainGenerator.new()
	terrain.name = "EmptyTerrain"
	terrain.build_on_start = false
	add_child(terrain)
	var driver: Node = get_node("/root/TickDriver")
	var participants_before: int = driver.get_participant_count()
	var pawn := _make_pawn(Vector3(5.0, 40.0, 5.0))
	_drive(pawn, Vector3(1.0, 0.0, 0.0))
	await _ticks(30)
	_check(pawn.is_frozen(), "an AI pawn with no ground is switched off")
	_check(is_equal_approx(pawn.position.y, 40.0) and is_equal_approx(pawn.position.x, 5.0), "so it stays exactly where it is")
	# Claude 2026-11-07: the bug this guards against: its entity and TickState kept ticking, so a pawn that was off still cost a lot.
	var entity: NetworkEntity = pawn.get_node("NetworkEntity")
	var state: TickStateComponent = pawn.get_node("TickState")
	_check(not driver.is_registered(pawn) and not driver.is_registered(entity) and not driver.is_registered(state), "and nothing of it ticks")
	pawn.controller_manager.set_has_player(true)
	_check(not pawn.is_frozen(), "a player taking it switches it on")
	_check(driver.is_registered(pawn) and driver.is_registered(entity) and driver.is_registered(state), "and all of it ticks again")
	pawn.controller_manager.set_has_player(false)
	await _ticks(2)
	_check(pawn.is_frozen(), "(it's off again)")
	pawn.free()
	await get_tree().process_frame
	_check(driver.get_participant_count() == participants_before, "and a pawn freed while it's off leaves nothing behind")
	terrain.free()


func _test_no_arms_by_default() -> void:
	var pawn := _make_pawn(Vector3.ZERO)
	_check(CameraMount.arm_of(pawn) == null, "a pawn has no camera arm by default")
	_check(CameraMount.mount_of(pawn) == pawn.get_visual() and CameraMount.preset_of(pawn) == null, "and with no CameraMount, the arm would go on Visual, with the defaults") # Claude 2026-11-16 (pawn M5)
	pawn.free()


func _test_visual_smoothing() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	await _ticks(20)
	var visual := pawn.get_visual()
	_check(visual != pawn and visual.top_level, "Visual follows on its own")
	pawn._on_network_corrected(Vector3(2.0, 0.0, 0.0))
	await get_tree().process_frame
	await get_tree().process_frame # the signal comes before this frame's _process
	_check(visual.global_position.distance_to(pawn.global_position) > 1.0, "a correction shows as an offset at first")
	for i in 40:
		await get_tree().process_frame
	_check(visual.global_position.distance_to(pawn.global_position) < 0.2, "and fades out quickly (%.2f m left)" % visual.global_position.distance_to(pawn.global_position))
	pawn.free()
	floor_body.free()


## Not a pass or fail, just numbers.
func _measure_a_crowd() -> void:
	var floor_body := _make_floor()
	var pawns: Array[Pawn] = []
	for i in 200:
		var pawn := _make_pawn(Vector3((i % 20) * 3.0 - 30.0, 0.1, (i / 20) * 3.0 - 15.0))
		_drive(pawn, Vector3(1.0, 0.0, 0.0))
		pawns.append(pawn)
	await _ticks(30)
	var started := Time.get_ticks_usec()
	for i in 60:
		TickDriver.step()
	print("        200 pawns walking: %.2f ms a tick" % ((Time.get_ticks_usec() - started) / 60000.0))
	for pawn in pawns:
		pawn.free()
	floor_body.free()


# --- Helpers ---


## Claude 2026-11-09: sleeping (pawn spec 15.3): a pawn standing still skips its abilities and move_and_slide, with a full check tick
## every sleep_check_ticks, and wakes for input, being moved, ground going away and hits. Sleeping changes nothing about where it ends up.
func _test_resting() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.2, 0.0))
	# Claude 2026-11-16 (wider audit): taken out of the tree and put back, a pawn is watched by the AI switch-off again.
	var watched: int = GameMode.ai_activation_manager.get_watched_count()
	var pawn_parent := pawn.get_parent()
	pawn_parent.remove_child(pawn)
	_check(GameMode.ai_activation_manager.get_watched_count() == watched - 1, "(a pawn taken out of the tree leaves the AI switch-off's list)")
	pawn_parent.add_child(pawn)
	_check(GameMode.ai_activation_manager.get_watched_count() == watched, "a pawn put back into the tree is watched by the AI switch-off again")
	# Claude 2026-11-16 (wider audit): a corpse lying still sleeps, and wakes when it's revived.
	var corpse := _make_pawn(Vector3(6.0, 0.2, 0.0))
	await _ticks(40)
	var killing_hit := HitInfo.new() # a hit with enough damage: Death starts when a hit takes Health to 0
	killing_hit.attacker = pawn
	killing_hit.target = corpse
	killing_hit.tick = TickDriver.tick
	killing_hit.effects = [Effect.make_damage(100000)]
	corpse.ability_manager.receive_hit(killing_hit)
	await _ticks(40)
	# Claude 2026-11-17: counted over 15 ticks. A sleeping pawn still runs one full tick in every sleep_check_ticks (15), so a check
	# of one tick failed about 1 time in 15 (it did once, in a full run).
	var asleep := 0
	for i in 15:
		await _ticks(1)
		if corpse.is_sleeping:
			asleep += 1
	_check(corpse.is_dead() and asleep >= 13, "a dead pawn lying still sleeps (dead %s, asleep %d of 15 ticks)" % [corpse.is_dead(), asleep])
	corpse.ability_manager.revive()
	await _ticks(3)
	_check(not corpse.is_dead(), "and a revived one wakes and is alive again within a few ticks")
	corpse.free()
	await _ticks(40)
	var rested := 0
	for i in 30:
		await _ticks(1)
		if pawn.is_sleeping:
			rested += 1
	_check(rested >= 26 and rested <= 28, "standing still it sleeps, with a full check tick every %d ticks (%d of 30 rested)" % [pawn.sleep_check_ticks, rested])
	_drive(pawn, Vector3(1.0, 0.0, 0.0))
	await _ticks(1)
	_check(not pawn.is_sleeping and pawn.velocity.x > 0.0, "a move input wakes it at once")
	_drive(pawn, Vector3.ZERO)
	await _ticks(60)
	# Claude 2026-11-09: counted over a check period, not looked at once, because one tick in sleep_check_ticks is a full check tick,
	# staggered by the pawn's instance id, which differs from run to run (this failed about 1 run in 15 on Linux).
	var rested_again := 0
	for i in pawn.sleep_check_ticks:
		await _ticks(1)
		if pawn.is_sleeping:
			rested_again += 1
	_check(rested_again == pawn.sleep_check_ticks - 1, "and once it has stopped, it sleeps again (%d of %d ticks)" % [rested_again, pawn.sleep_check_ticks])
	# Claude 2026-11-21: through Pawn.teleport, which is what wakes it now; a position set directly no longer does.
	pawn.teleport(pawn.global_position + Vector3(0.0, 2.0, 0.0))
	await _ticks(1)
	_check(not pawn.is_sleeping, "moved by something else (a teleport into the air): it wakes")
	await _ticks(60)
	_check(pawn.grounded and absf(pawn.position.y) < 0.05, "and falls back to the ground (%.3f m)" % pawn.position.y)
	await _ticks(20)
	var hit := HitInfo.new()
	hit.target = pawn
	hit.direction = Vector3(0.0, 0.0, 1.0)
	hit.effects = [Effect.make_knockback(6.0, 10)] # Claude 2026-11-10: hits carry effects now (pawn spec 8.11)
	var before := pawn.position.z
	pawn.ability_manager.receive_hit(hit)
	await _ticks(3)
	_check(not pawn.is_sleeping and pawn.position.z > before + 0.1, "a hit's knockback wakes it (pushed %.2f m)" % (pawn.position.z - before))
	await _ticks(60)
	floor_body.free()
	var fell_after := -1
	for i in pawn.sleep_check_ticks + 5:
		await _ticks(1)
		if not pawn.grounded:
			fell_after = i + 1
			break
	_check(fell_after > 0 and fell_after <= pawn.sleep_check_ticks + 1, "ground taken away from under a sleeping pawn: it starts falling on its next check tick (after %d ticks)" % fell_after)
	pawn.free()

	# The same input script, once sleeping and once never sleeping, ends in exactly the same place.
	floor_body = _make_floor()
	var resting_pawn := _make_pawn(Vector3(0.0, 0.2, 0.0))
	var awake_pawn := _make_pawn(Vector3(10.0, 0.2, 0.0))
	awake_pawn.sleep_when_idle = false
	var plan := [[40, Vector3.ZERO, false], [25, Vector3(1.0, 0.0, 0.3), false], [30, Vector3.ZERO, false], [1, Vector3.ZERO, true], [50, Vector3.ZERO, false], [20, Vector3(-0.5, 0.0, 1.0), false], [45, Vector3.ZERO, false]]
	var awake_ever_rested := false
	for step in plan:
		for i in step[0]:
			_drive(resting_pawn, step[1], false, step[2])
			_drive(awake_pawn, step[1], false, step[2])
			await _ticks(1)
			awake_ever_rested = awake_ever_rested or awake_pawn.is_sleeping
	var offset := resting_pawn.global_position - (awake_pawn.global_position - Vector3(10.0, 0.0, 0.0))
	_check(not awake_ever_rested, "with sleep_when_idle off it never sleeps")
	_check(offset.length() < 0.0015, "walking, stopping, jumping and standing: sleeping ends exactly where never sleeping does (%.4f m apart)" % offset.length())
	resting_pawn.free()
	awake_pawn.free()
	floor_body.free()


# Claude 2026-11-16 (movement experiments): an ability that always has something to do, so its pawn never sleeps: awake, but still.
class BusyAbility extends AbilityBase:
	# The manager only asks abilities that run every tick whether the pawn may sleep (pawn spec 15.2), so this is one.
	func every_tick(_dt: float) -> void:
		pass

	func can_sleep() -> bool:
		return false


# Claude 2026-11-16 (movement experiments): skip_move_when_still. A pawn kept awake but standing still skips move_and_slide (counted in
# diagnostics as pawn.move_skipped) and stays put; with its floor taken away, a check tick still notices, and it falls.
func _test_skipping_still_moves() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	var busy := BusyAbility.new()
	busy.name = "Busy"
	pawn.ability_manager.add_child(busy)
	pawn.ability_manager._collect_abilities()
	await _ticks(30)
	var diagnostics := GameMode.get_module(DiagnosticsManager) as DiagnosticsManager
	var skipped := 0
	if diagnostics:
		for record: Dictionary in diagnostics.get_frames().slice(-15):
			skipped += int(record.scopes.get(&"pawn.move_skipped", [0, 0])[1])
	var at := pawn.global_position
	await _ticks(10)
	_check(pawn.skip_move_when_still and not pawn.is_sleeping and skipped > 0 and pawn.global_position == at and pawn.grounded,
		"an awake pawn standing still skips its moves (%d skipped in 15 frames) and stays put (velocity %s, grounded %s, sleeping %s)" % [skipped, pawn.velocity, pawn.grounded, pawn.is_sleeping])
	floor_body.free()
	var fell := false
	for i in pawn.sleep_check_ticks + 10:
		await get_tree().physics_frame
		if pawn.global_position.y < at.y - 0.05:
			fell = true
			break
	_check(fell, "with its floor gone, a check tick notices and it falls")
	pawn.free()


func _make_floor() -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 1.0, 4000.0)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)
	return body


# Claude 2026-11-07: skip leaves out default parts by name, through the pawn's own skip_default_parts.
func _make_pawn(at: Vector3, skip: Array[StringName] = []) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	pawn.skip_default_parts = skip
	add_child(pawn)
	return pawn


## Claude 2026-11-07: gives the pawn one tick's input. It replaces the old apply_player_input(move, 0, 0, sprint, jump) calls.
# Claude 2026-11-07: through the pawn's AI controller when it's in charge, since the pawn now asks it for input every tick and anything
# written straight onto the pawn would be replaced. A pawn with no ControllerManager gets the input written onto it directly.
func _drive(pawn: Pawn, move: Vector3, sprint := false, jump := false) -> void:
	var manager := pawn.controller_manager
	var ai := manager.ai_controller as AIController if manager else null
	if ai and manager.get_controller_in_charge() == ai:
		ai.move_in_direction(move)
		ai.hold(&"sprint", sprint)
		ai.hold(&"jump", jump)
		return
	var held: Array[StringName] = []
	if sprint:
		held.append(&"sprint")
	if jump:
		held.append(&"jump")
	pawn.controller_manager.apply_input(InputCommand.make(move, held))


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
