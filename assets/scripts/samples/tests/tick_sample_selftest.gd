## Written by Claude (claude-opus-5-5), 2026-11-04: headless check that the tick driver sample scene actually runs on NetworkTime.
## Loads tick_pawn_sample.tscn, lets real physics frames pass, and checks the pawns tick, move, record history,
## and move the same distance per second at different tick rates. Exits 0 on success, 1 on failure. Run from the project folder:
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/samples/tests/tick_sample_selftest.tscn"
extends Node

var _failures := 0


func _ready() -> void:
	print("--- Tick sample self-test ---")
	var nt: NetworkTimeSingleton = get_node("/root/NetworkTime")
	var sample: Node3D = load("res://tick_pawn_sample.tscn").instantiate()
	add_child(sample)
	var player: TickSamplePawn = sample.get_node("Player")
	var wanderer: TickSamplePawn = sample.get_node("WandererA")
	var wanderer_start := wanderer.global_position

	_check(nt.is_registered(player) and nt.is_registered(wanderer), "pawns register with NetworkTime on entering the tree")
	_check(not player.is_physics_processing(), "their own _physics_process is off (the driver calls them)")

	await _frames(30) # settle on the floor
	_check(player.is_on_floor(), "player lands on the floor (move_and_slide runs inside ticks)")
	var t0 := nt.tick

	await _frames(120)
	_check(nt.tick - t0 == 120, "one tick per physics frame at the default rate")
	_check(wanderer.global_position.distance_to(wanderer_start) > 0.5, "wanderer moved by itself (seeded wander, timers in ticks)")
	_check(player.global_position.distance_to(Vector3.ZERO) < 0.05, "player without input stays put")
	# Claude 2026-11-04: recording moved from the pawn to its TickState child node
	var state: TickStateComponent = player.get_node("TickState")
	var rec := state.get_state(nt.tick)
	_check(not rec.is_empty() and rec["position"].is_equal_approx(player.position), "TickState stored this tick's state")
	_check(state.get_state(nt.tick - 100).is_empty(), "history only keeps the last 64 ticks")

	# Hold forward for one second at the physics rate, then at 20 ticks/s: same distance either way.
	var d60 := await _walk_one_second(nt, player, 0)
	var d20 := await _walk_one_second(nt, player, 20)
	print("        distance in 1 s: %.2f m at 60/s, %.2f m at 20/s" % [d60, d20])
	_check(d60 > 3.5 and d60 < 5.1, "walks roughly max_speed for a second at 60 ticks/s")
	_check(absf(d20 - d60) < d60 * 0.12, "physics_factor: same distance per second at 20 ticks/s")
	_check(nt.get_tick_rate() == Engine.physics_ticks_per_second, "tick rate restored")

	await _test_wanderers_stay_on_the_ground(sample) # Claude 2026-11-05

	nt.active = false
	var paused_at := nt.tick
	await _frames(10)
	_check(nt.tick == paused_at, "NetworkTime.active = false pauses all pawns")
	nt.active = true

	sample.queue_free()
	await _frames(2)
	_check(nt.get_participant_count() == 0, "freed pawns leave the driver")

	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## Claude 2026-11-05: wanderers on a small platform, far from the sample's floor. The ones with the ground check off show that
## this test can really see a pawn fall: one wander decision walks further than the platform is wide.
func _test_wanderers_stay_on_the_ground(sample: Node3D) -> void:
	var careful := _add_wanderers_on_platform(sample, Vector3(500, 0, 0), "Careful", 1.5)
	var careless := _add_wanderers_on_platform(sample, Vector3(-500, 0, 0), "Careless", 0.0)
	var starts: Array[Vector3] = []
	for pawn in careful:
		starts.append(pawn.global_position)
	await _frames(600)
	var careful_fallen := 0
	var careful_moved := 0
	for i in careful.size():
		if careful[i].global_position.y < -1.0:
			careful_fallen += 1
		if careful[i].global_position.distance_to(starts[i]) > 0.5:
			careful_moved += 1
	var careless_fallen := 0
	for pawn in careless:
		if pawn.global_position.y < -1.0:
			careless_fallen += 1
	print("        fallen after 10 s: %d of %d with the check, %d of %d without" % [careful_fallen, careful.size(), careless_fallen, careless.size()])
	_check(careless_fallen > 0, "wanderers without the ground check walk off a small platform")
	_check(careful_fallen == 0, "wanderers with the ground check stay on it")
	_check(careful_moved > 0, "and they keep walking")


func _add_wanderers_on_platform(sample: Node3D, at: Vector3, label: String, look_ahead: float) -> Array[TickSamplePawn]:
	var platform := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6, 1, 6)
	shape.shape = box
	platform.add_child(shape)
	platform.position = at + Vector3(0, -0.5, 0)
	sample.add_child(platform)
	var pawns: Array[TickSamplePawn] = []
	var pawn_scene: PackedScene = load("res://assets/scenes/samples/tick_sample_pawn.tscn")
	for offset: Vector3 in [Vector3(-1, 0.1, -1), Vector3(1, 0.1, -1), Vector3(-1, 0.1, 1), Vector3(1, 0.1, 1)]:
		var pawn: TickSamplePawn = pawn_scene.instantiate()
		pawn.name = "%s%d" % [label, pawns.size()]
		pawn.brain = TickSamplePawn.Brain.WANDER
		pawn.wander_look_ahead = look_ahead
		pawn.position = at + offset
		sample.add_child(pawn)
		pawns.append(pawn)
	return pawns


func _walk_one_second(nt: NetworkTimeSingleton, pawn: TickSamplePawn, rate: int) -> float:
	nt.tick_rate = rate
	await _frames(40) # let it come to rest
	var start := pawn.global_position
	Input.action_press(&"move_forward")
	await _frames(Engine.physics_ticks_per_second)
	Input.action_release(&"move_forward")
	var d := Vector2(pawn.global_position.x - start.x, pawn.global_position.z - start.z).length()
	nt.tick_rate = 0
	return d


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
