## Written by Claude (claude-opus-5-5), 2026-11-12: headless self-test for the toy visuals (ToyWaddle and FloatingSword) and the swing's
## up-and-down sweep (MeleeAttackAbility.height_at_sweep_start and _end): each faction's scene makes its model and sword, the model
## waddles only while the pawn moves and falls over when it dies, the sword points through the spots the hit checks during a swing,
## and the heights move the hit area.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/visuals/tests/visuals_selftest.tscn"
extends Node

const PLAYER_SCENE := "res://assets/scenes/samples/faction_player.tscn"
const RED_SCENE := "res://assets/scenes/samples/faction_goblin.tscn"
const BLUE_SCENE := "res://assets/scenes/samples/faction_goblin_blue.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]

var _failures := 0


func _ready() -> void:
	print("--- Visuals self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_scenes()
	await _test_waddle()
	await _test_sword()
	await _test_heights()
	await _test_alternating_sides() # Claude 2026-11-12
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_scenes() -> void:
	var models := {}
	for path in [PLAYER_SCENE, RED_SCENE, BLUE_SCENE]:
		var pawn := _pawn(path, Vector3.ZERO)
		await _frames(3)
		var waddle := pawn.get_node_or_null(^"Visual/Model/Waddle") as ToyWaddle
		var sword := pawn.get_node_or_null(^"Visual/FloatingSword") as FloatingSword
		var made_model := waddle != null and waddle.find_children("*", "Skeleton3D", true, false).size() == 1
		var has_stand := waddle != null and waddle.get_node_or_null(^"Stand") != null
		var body_hidden := not (pawn.get_node(^"Visual/Model/Body") as Node3D).visible
		_check(made_model and has_stand and sword != null and sword.get_child_count() == 1 and body_hidden, "%s: a waddling model on a base, a floating sword, and the capsule hidden" % path.get_file())
		models[path] = waddle.toy_scene.resource_path if waddle else ""
		pawn.free()
	_check(models[PLAYER_SCENE].ends_with("knight.glb") and models[RED_SCENE].ends_with("orc.glb") and models[BLUE_SCENE].ends_with("zombie.glb"), "the factions are a knight, an orc and a zombie")


func _test_waddle() -> void:
	var pawn := _pawn(PLAYER_SCENE, Vector3(0, 0.1, 0))
	var waddle: ToyWaddle = pawn.get_node(^"Visual/Model/Waddle")
	await _frames(30)
	var still := _sample(waddle, 30)
	await still.done
	_check(still.most_rock < deg_to_rad(1.0) and still.most_hop < 0.03, "standing still: no rocking and no hop, only a slight breathing bob (rock %.2f deg, rise %.3f m)" % [rad_to_deg(still.most_rock), still.most_hop])
	_ai(pawn).move_in_direction(Vector3(1, 0, 0))
	await _frames(30)
	var moving := _sample(waddle, 60)
	await moving.done
	_check(moving.most_rock > deg_to_rad(5.0) and moving.most_hop > 0.04 and moving.leaned_forward, "walking: it rocks side to side, hops and leans forward (rock %.1f deg, hop %.3f m)" % [rad_to_deg(moving.most_rock), moving.most_hop])
	_ai(pawn).stop()
	pawn.stat_manager.change_current(&"Health", -1000.0)
	pawn.health_ran_out(null)
	await _frames(90)
	_check(pawn.is_dead() and absf(waddle.rotation.z) > deg_to_rad(70.0), "dead: it falls over on its side (%.0f deg)" % rad_to_deg(absf(waddle.rotation.z)))
	var sword: FloatingSword = pawn.get_node(^"Visual/FloatingSword")
	_check(sword.global_position.y < 0.3, "and the sword drops to the ground (%.2f m up)" % sword.global_position.y)
	pawn.free()


func _test_sword() -> void:
	var pawn := _pawn(PLAYER_SCENE, Vector3(0, 0.1, 0))
	var sword: FloatingSword = pawn.get_node(^"Visual/FloatingSword")
	var swing: MeleeAttackAbility = pawn.ability_manager.get_node("FinisherSwing") # the vertical chop
	await _frames(40)
	var right := Vector3(cos(pawn.yaw), 0, -sin(pawn.yaw))
	var hovering := sword.global_position - pawn.global_position
	_check(hovering.dot(right) > 0.5 and absf(hovering.y - sword.hover_height) < 0.2, "hovering: at the pawn's right, about chest high (%.2f right, %.2f up)" % [hovering.dot(right), hovering.y])
	pawn.ability_manager.start_ability(swing)
	var worst := 0.0
	var samples := 0
	var lowest := 10.0
	var highest := -10.0
	while swing.is_running_timed():
		await get_tree().process_frame
		var elapsed := swing.ticks_running()
		if elapsed < swing.windup_length() + 2 or elapsed >= swing.windup_length() + swing.hit_length():
			continue # the first ticks of the hit let the sword catch up from the windup
		var pivot := pawn.get_visual().global_position + Vector3(0, sword.swing_pivot_height, 0)
		var progress := (elapsed - swing.windup_length() + TickDriver.get_interpolation_fraction()) / float(swing.hit_length())
		var aim := (pawn.get_visual().global_position + swing.hit_offset_at(progress, pawn.yaw) - pivot).normalized()
		worst = maxf(worst, rad_to_deg(sword.global_basis.y.normalized().angle_to(aim)))
		var tip := sword.global_position + sword.global_basis.y.normalized() * 1.0 # about the drawn blade's length
		lowest = minf(lowest, tip.y)
		highest = maxf(highest, tip.y)
		samples += 1
	_check(samples > 0 and worst < 25.0, "during the hit, the blade points through the spot the hit checks (worst %.1f deg over %d frames)" % [worst, samples])
	_check(highest - lowest > 0.6, "and a chop brings its tip down as the hit area drops (%.2f m)" % (highest - lowest))
	await _frames(60)
	var back := sword.global_position - pawn.global_position
	_check(back.dot(right) > 0.5, "afterwards it drifts back to hovering at the pawn's right")
	pawn.free()


func _test_heights() -> void:
	var pawn := _pawn(PLAYER_SCENE, Vector3(0, 0.1, 0))
	await _frames(3)
	var finisher: MeleeAttackAbility = pawn.ability_manager.get_node("FinisherSwing")
	var feet := pawn.global_position
	_check(is_equal_approx(finisher.hit_centre_at(0.0).y - feet.y, finisher.hit_height + 1.3) and is_equal_approx(finisher.hit_centre_at(1.0).y - feet.y, finisher.hit_height - 0.8), "the hit area starts height_at_sweep_start above hit_height and ends height_at_sweep_end from it")
	var heavy: MeleeAttackAbility = pawn.ability_manager.get_node("HeavyAttack")
	_check(heavy.height_at_sweep_start == 0.0 and heavy.height_at_sweep_end == 0.0 and is_equal_approx(heavy.hit_centre_at(0.3).y - feet.y, heavy.hit_height), "by default it stays level at hit_height, as before")
	var centres := finisher._sweep_centres(0)
	var gap := 0.0
	for i in range(1, centres.size()):
		gap = maxf(gap, centres[i].distance_to(centres[i - 1]))
	_check(centres.size() >= 2 and gap <= finisher.hit_radius * 0.5 + 0.001, "a chop that drops fast still checks spots no more than half the radius apart (%d spots, %.2f m apart at most)" % [centres.size(), gap])
	pawn.free()


# Claude 2026-11-12: after a swing the sword rests on the side the swing ended on, so the combo's swings alternate, and goes back to
# the right after return_seconds.
func _test_alternating_sides() -> void:
	var pawn := _pawn(PLAYER_SCENE, Vector3(0, 0.1, 0))
	var sword: FloatingSword = pawn.get_node(^"Visual/FloatingSword")
	await _frames(30)
	var right := Vector3(cos(pawn.yaw), 0, -sin(pawn.yaw))
	var swing: MeleeAttackAbility = pawn.ability_manager.get_node("MeleeAttack") # right to left
	var second: MeleeAttackAbility = pawn.ability_manager.get_node("SecondSwing") # left to right
	pawn.ability_manager.start_ability(swing)
	await _until_done(swing)
	await _frames(4)
	var after_swing := (sword.global_position - pawn.global_position).dot(right)
	_check(after_swing < -0.5, "a swing ending on the left leaves the sword hovering at the pawn's left (%.2f)" % after_swing)
	pawn.ability_manager.start_ability(second)
	await _frames(2)
	var at_windup := (sword.global_position - pawn.global_position).dot(right)
	await _until_done(second)
	await _frames(4)
	var after_second := (sword.global_position - pawn.global_position).dot(right)
	_check(at_windup < 0.0 and after_second > 0.5, "the second swing starts from the left and leaves it at the right (%.2f, then %.2f)" % [at_windup, after_second])
	pawn.ability_manager.start_ability(swing)
	await _until_done(swing)
	var longest_wait := int((sword.return_seconds + sword.side_change_seconds) * 60.0) + 20
	var passed_in_front := false
	for i in longest_wait:
		await get_tree().physics_frame
		var offset := sword.global_position - pawn.global_position
		var forward := Vector3(-sin(pawn.yaw), 0, -cos(pawn.yaw))
		if absf(offset.dot(right)) < 0.3:
			passed_in_front = passed_in_front or offset.dot(forward) > 0.5
	var back := (sword.global_position - pawn.global_position).dot(right)
	_check(back > 0.7 and passed_in_front, "left alone, it goes back to the right, round the front of the pawn (%.2f)" % back)
	pawn.free()


func _until_done(ability: AbilityBase) -> void:
	for i in 120:
		if not ability.is_running_timed():
			return
		await get_tree().physics_frame


# --- Helpers ---


# Watches a waddle for some frames: the most it rocked and rose, and whether it leaned forward. Await its done signal.
class Sample:
	signal done
	var most_rock := 0.0
	var most_hop := 0.0
	var leaned_forward := false


func _sample(waddle: ToyWaddle, frames: int) -> Sample:
	var sample := Sample.new()
	_run_sample(waddle, frames, sample)
	return sample


func _run_sample(waddle: ToyWaddle, frames: int, sample: Sample) -> void:
	for i in frames:
		await get_tree().process_frame
		sample.most_rock = maxf(sample.most_rock, absf(waddle.rotation.z))
		sample.most_hop = maxf(sample.most_hop, waddle.position.y)
		sample.leaned_forward = sample.leaned_forward or waddle.rotation.x < -deg_to_rad(2.0)
	sample.done.emit()


func _pawn(path: String, at: Vector3) -> Pawn:
	var pawn: Pawn = load(path).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.position = at
	add_child(pawn)
	return pawn


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
