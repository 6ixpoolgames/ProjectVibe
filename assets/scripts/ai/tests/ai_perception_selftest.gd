## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for AIMemory, AISensingManager, SightSense and AITargetSelector
## (pawn spec 10.4 and 10.5). Checks awareness filling and fading, spotting, forgetting, each part of sight's gain (distance, angle,
## line of sight, detectability, the time factor and its cap), which way the eyes face, teams, sensing on schedule and while
## possessed, and target selection with its bonus, threat and forced targets.
## Claude 2026-11-09: add "-- --gdscript-store" to check the GDScript memory store where the C++ one is available.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/ai/tests/ai_perception_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NEVER := 100000000

var _failures := 0
var _floor: StaticBody3D = null


func _ready() -> void:
	print("--- AI perception self-test ---")
	# Claude 2026-11-09: "-- --gdscript-store" runs the same checks on the GDScript memory store, where the C++ one is available.
	AIMemory.use_native = not OS.get_cmdline_user_args().has("--gdscript-store")
	print("  memory store: %s" % ("C++" if AIMemory.use_native and ClassDB.class_exists(&"AIMemoryStore") else "GDScript"))
	_floor = _make_box(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	await _test_memory()
	await _test_held_in_view()
	await _test_sight()
	await _test_eyes()
	await _test_scheduled_sensing()
	await _test_target_selection()
	await _test_stores_agree()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_memory() -> void:
	var observer := await _make_pawn(1, Vector3.ZERO)
	var a := await _make_pawn(0, Vector3(0, 0, -5))
	var b := await _make_pawn(0, Vector3(3, 0, -3))
	var memory := observer.ai_memory
	var certain := []
	var forgotten := []
	memory.entity_became_certain.connect(func(e): certain.append(e))
	memory.entity_forgotten.connect(func(e): forgotten.append(e))
	observer.ai_context.clear_decision()
	memory.record_sighting(a, 0.5, 1000, a.global_position)
	var i := memory.find(a)
	_check(i == 0 and is_equal_approx(memory.awareness_at(i, 1000), 0.5), "a first sighting makes an entry with its gain as awareness")
	_check(observer.ai_context.has_decision_waiting(), "and asks for a decision at once")
	_check(is_equal_approx(memory.awareness_at(i, 1300), 0.5), "uncertain, it holds for 300 ticks (the default)")
	_check(is_equal_approx(memory.awareness_at(i, 1450), 0.25), "then fades in a straight line: half gone 150 ticks after that (%.3f)" % memory.awareness_at(i, 1450))
	memory.record_sighting(a, 0.6, 1450, a.global_position)
	_check(is_equal_approx(memory.awareness_at(i, 1450), 0.85), "a sighting adds to what's left: 0.25 + 0.6")
	observer.ai_context.clear_decision()
	memory.record_sighting(a, 0.3, 1460, a.global_position)
	_check(memory.is_certain_at(i) and certain == [a], "reaching 1: certain, with entity_became_certain")
	_check(observer.ai_context.has_decision_waiting(), "and a decision is asked for")
	_check(is_equal_approx(memory.awareness_at(i, 2060), 0.5), "certain, it fades over 1200 ticks instead, with no hold: half gone 600 ticks later")
	memory.record_sighting(a, 0.01, 1760, a.global_position)
	_check(is_equal_approx(memory.awareness_at(i, 1760), 1.0), "seeing a certain entity again refills it to 1, whatever the gain")
	memory.record_sighting(b, 0.2, 1760, b.global_position)
	memory.forget_old(2359)
	_check(memory.entry_count() == 2, "an uncertain entry is kept until its fade ends (599 ticks)")
	memory.forget_old(2360)
	_check(memory.entry_count() == 1 and memory.find(b) < 0 and forgotten == [b], "and forgotten at 600, with entity_forgotten")
	memory.forget_old(2959)
	_check(memory.find(a) >= 0, "a certain entry is kept for 1199 ticks")
	memory.forget_old(2960)
	_check(memory.entry_count() == 0, "and forgotten at 1200")
	memory.record_sighting(a, 0.4, 3000, a.global_position)
	memory.record_sighting(b, 0.4, 3000, b.global_position)
	_check(memory.entity_at(memory.most_aware_index(3000)) == b, "most aware: a tie goes to the nearer last known position")
	memory.record_sighting(a, 0.3, 3000, a.global_position)
	_check(memory.entity_at(memory.most_aware_index(3000)) == a, "and otherwise to the higher awareness")
	memory.add_threat(a, 2.5)
	_check(is_equal_approx(memory.threat_at(memory.find(a)), 2.5), "add_threat adds to its entry")
	b.free()
	memory.forget_old(3001)
	_check(memory.find(a) >= 0 and memory.entry_count() == 1, "a freed entity is forgotten on the next pass")
	observer.free()
	a.free()


## Claude 2026-11-09: awareness doesn't fade while the target is in view: between checks that see it, it's held, and it only starts
## to fade (counted from when it was last seen) once a check misses it, or once continuous_sighting_ticks pass with no check at all.
## And an entry held in view isn't forgotten, even with a fade shorter than that. Both stores.
func _test_held_in_view() -> void:
	var observer := await _make_pawn(1, Vector3.ZERO)
	var a := await _make_pawn(0, Vector3(0, 0, -5))
	var memory := observer.ai_memory
	memory.record_sighting(a, 1.0, 8000, a.global_position) # certain at once; a certain entry fades from the next tick
	var i := memory.find(a)
	_check(memory.awareness_at(i, 8004) == 1.0, "a certain target seen 4 ticks ago, with no check since: still exactly 1, not 0.997 (it's in view)")
	memory.record_sighting(a, 0.01, 8005, a.global_position)
	_check(memory.awareness_at(i, 8009) == 1.0 and memory.awareness_at(i, 8035) == 1.0, "seen again: held for up to continuous_sighting_ticks (30)")
	_check(memory.awareness_at(i, 8036) < 1.0, "past that with no check at all, it fades, counted from when it was seen")
	memory.record_check(observer, 8006) # a check of someone else changes nothing for a
	memory.record_check(a, 8010) # a check that missed it
	_check(is_equal_approx(memory.awareness_at(i, 8010), 1.0 - 5.0 / 1200.0), "a check that misses it: it fades from the last sighting, 5 ticks' worth (%.4f)" % memory.awareness_at(i, 8010))
	for store in [ClassDB.instantiate(&"AIMemoryStore") if ClassDB.class_exists(&"AIMemoryStore") else null, AIMemoryStoreGD.new()]:
		if store == null:
			continue
		var short := FadeProfile.new()
		short.mode = FadeProfile.Mode.LINEAR
		short.hold_ticks = 0
		short.fade_ticks = 10
		store.configure_fades(short, 0, false, short, 0, false, 30)
		store.record_sighting(a, 1.0, 100, a.global_position)
		store.forget_old(120)
		var kept: bool = store.entry_count() == 1
		store.forget_old(131)
		_check(kept and store.entry_count() == 0, "%s store: a 10-tick fade isn't forgotten while held in view (20 ticks), and is once that ends" % ("C++" if store is not AIMemoryStoreGD else "GDScript"))
	observer.free()
	a.free()


func _test_sight() -> void:
	var observer := await _make_pawn(1, Vector3.ZERO) # faces -Z
	# A real interval, because a first sighting counts this many ticks. Passes below are made by hand, at ticks the test picks.
	observer.ai_sensing_manager.sense_interval_ticks = 10
	var sight: SightSense = observer.ai_sensing_manager.get_node("Sight")
	var memory := observer.ai_memory
	var front := await _make_pawn(0, Vector3(0, 0, -5))
	observer.ai_sensing_manager.full_pass(5000)
	var i := memory.find(front)
	_check(i >= 0 and is_equal_approx(memory.awareness_at(i, 5000), 10.0 / 30.0), "in front at 5 m: a first pass adds 10 ticks' worth, 1/3 (%.3f)" % memory.awareness_at(i, 5000))
	observer.ai_sensing_manager.full_pass(5005)
	_check(is_equal_approx(memory.awareness_at(i, 5005), 0.5), "a pass 5 ticks later adds 5 ticks' worth: the checking rate doesn't matter")
	observer.ai_sensing_manager.full_pass(5020)
	_check(memory.is_certain_at(i), "after 20 ticks in front, close: certain (basically instant)")
	front.free()
	memory.clear()

	var behind := await _make_pawn(0, Vector3(0, 0, 5))
	observer.ai_sensing_manager.full_pass(5100)
	_check(memory.find(behind) < 0, "behind it: never seen")
	behind.free()

	var side := await _make_pawn(0, Vector3(5.0 * sin(deg_to_rad(60.0)), 0, -5.0 * cos(deg_to_rad(60.0))))
	_check(is_equal_approx(sight.visibility_of(side), 0.3), "60 degrees off, in the periphery: 0.3 of full strength")
	side.global_position = Vector3(0, 0, -16.5)
	_check(absf(sight.visibility_of(side) - 0.5) < 0.01, "half way between near_range and sight_range: about half (%.3f)" % sight.visibility_of(side))
	side.global_position = Vector3(0, 0, -26)
	_check(sight.visibility_of(side) == 0.0, "beyond sight_range: nothing")
	side.global_position = Vector3(0, 0, -5)
	side.detectability = 0.5
	_check(is_equal_approx(sight.visibility_of(side), 0.5), "detectability 0.5: half")
	side.detectability = 0.0
	observer.ai_sensing_manager.full_pass(5200)
	_check(memory.find(side) < 0, "detectability 0: invisible")
	side.detectability = 0.2
	observer.ai_sensing_manager.full_pass(5300)
	var faded_before := memory.awareness_at(memory.find(side), 5800) # what's left 500 ticks later, before the next pass
	observer.ai_sensing_manager.full_pass(5800)
	var gained := memory.awareness_at(memory.find(side), 5800) - faded_before
	_check(absf(gained - 0.2) < 0.001, "a long gap counts as max_gain_ticks (30) at most: +0.2, not +3.3 (%.3f)" % gained)
	side.detectability = 1.0
	memory.clear()

	var wall := _make_box(Vector3(0, 1, -2.5), Vector3(4, 2, 0.5))
	await _ticks(2)
	_check(not sight.has_line_of_sight(side), "a wall between them blocks the ray")
	observer.ai_sensing_manager.full_pass(6000)
	_check(memory.find(side) < 0, "so nothing behind the wall is seen")
	wall.free()
	await _ticks(2)
	_check(sight.has_line_of_sight(side), "and with the wall gone, it's seen")
	memory.clear() # a scheduled pass may have run during the waits
	side.team = 1
	observer.ai_sensing_manager.full_pass(6100)
	_check(memory.find(side) < 0, "a pawn on its own team never goes into memory")
	_check(Pawn.count_pawns_not_on_team(1) == 0, "with everyone on one team, there's no one to look for, so the query is skipped")
	side.team = 0
	_check(Pawn.count_pawns_not_on_team(1) == 1, "changing team updates the counts")
	side.free()
	observer.free()


func _test_eyes() -> void:
	var observer := await _make_pawn(1, Vector3.ZERO)
	var target := await _make_pawn(0, Vector3(0, 0, 5)) # behind it
	var sight: SightSense = observer.ai_sensing_manager.get_node("Sight")
	var hands: AIController = observer.controller_manager.ai_controller
	_check(sight.visibility_of(target) == 0.0, "eyes face the way the body faces: a pawn behind isn't seen")
	hands.look_at_point(Vector3(0, 1, 10))
	await _ticks(2) # the look reaches the pawn through its input
	_check(sight.visibility_of(target) > 0.9, "looking behind it (look_at_point): now it is")
	hands.stop_looking()
	_check(sight.visibility_of(target) == 0.0, "stop_looking: back to the body's facing")
	observer.set_has_player(true)
	observer.look_yaw = PI # a player looking behind
	_check(sight.visibility_of(target) > 0.9, "while a player has it: where the player looks")
	observer.set_has_player(false)
	observer.free()
	target.free()


func _test_scheduled_sensing() -> void:
	var observer := await _make_pawn(1, Vector3.ZERO, true)
	var target := await _make_pawn(0, Vector3(0, 0, -6))
	var memory := observer.ai_memory
	var ticks := await _until(func() -> bool: return memory.find(target) >= 0 and memory.is_certain_at(memory.find(target)), 120)
	_check(ticks >= 0 and ticks < 60, "on schedule (passes and refreshes): certain in front, close, within a second (%d ticks)" % ticks)
	memory.clear()
	observer.ai_context.while_possessed = AIContextComponent.WhilePossessed.MEMORY_ONLY
	observer.set_has_player(true)
	observer.look_yaw = 0.0
	ticks = await _until(func() -> bool: return memory.find(target) >= 0, 60)
	_check(ticks >= 0, "while possessed with MEMORY_ONLY, sensing still fills memory")
	observer.set_has_player(false)
	observer.free()
	target.free()


func _test_target_selection() -> void:
	var observer := await _make_pawn(1, Vector3.ZERO)
	var far := await _make_pawn(0, Vector3(0, 0, -20))
	var near := await _make_pawn(0, Vector3(0, 0, -3))
	var memory := observer.ai_memory
	var selector := observer.ai_target_selector
	var changes := []
	selector.target_changed.connect(func(old, new, reason): changes.append([old, new, reason]))
	_remember(memory, far, 0.9, near, 0.5, 7000)
	selector.update_target(7000)
	# far: 0.9 + 0.5 × (1 - 20/25) = 1.0; near: 0.5 + 0.5 × (1 - 3/25) = 0.94
	_check(selector.get_current_target() == far and observer.ai_context.current_target == far, "the highest priority is the target, and it goes on the context")
	_check(changes.size() == 1 and changes[0][1] == far, "target_changed, once")
	selector.distance_weight = 0.0 # awareness alone, from here, to see the bonus clearly
	_remember(memory, far, 0.8, near, 1.0, 7010)
	selector.update_target(7010)
	_check(selector.get_current_target() == far, "the current target's +0.3 bonus keeps it (1.1) against a higher priority (1.0)")
	_remember(memory, far, 0.8, near, 1.0, 7070)
	selector.update_target(7070)
	_check(selector.get_current_target() == far, "still, 10 ticks into the bonus's fade (+0.25)")
	_remember(memory, far, 0.8, near, 1.0, 7130)
	selector.update_target(7130)
	_check(selector.get_current_target() == near and changes.size() == 2, "once the bonus has faded, the higher priority wins")
	_remember(memory, far, 0.5, near, 0.5, 7300)
	selector.distance_weight = 0.5
	selector.update_target(7300)
	_check(selector.get_current_target() == near, "with equal awareness, the nearer is the target (distance_weight)")
	selector.distance_weight = 0.0
	memory.add_threat(far, 1.0)
	selector.update_target(7300)
	_check(selector.get_current_target() == far, "threat counts: +1 threat puts the far one on top")
	selector.distance_weight = 0.5
	memory.clear()
	memory.record_sighting(near, 0.2, 7200, near.global_position)
	selector.update_target(7200)
	_check(selector.get_current_target() == null, "below min_awareness (0.3): not a target")
	memory.record_sighting(far, 0.9, 7200, far.global_position)
	selector.update_target(7200)
	_check(selector.force_target(near, 30, 10, "taunt"), "force_target is accepted")
	_check(selector.get_current_target() == near and observer.ai_context.waiting_event_priority() == 10, "it takes effect at once, and asks for a decision with its priority")
	print("  (a refused forced target is logged next)")
	_check(not selector.force_target(far, 30, 5, "weaker"), "a weaker forced target is refused")
	selector.update_target(TickDriver.tick + 1)
	_check(selector.get_current_target() == near, "while forced, picking by priority is skipped")
	selector.check_force_expiry(TickDriver.tick + 31)
	selector.update_target(TickDriver.tick + 31)
	_check(selector.get_current_target() == far and not selector.is_target_forced(), "after hold_ticks, picking by priority again")
	selector.force_target(near, -1, 1, "until released")
	selector.release_forced_target()
	selector.update_target(TickDriver.tick + 32)
	_check(selector.get_current_target() == far, "release_forced_target hands back")
	observer.free()
	far.free()
	near.free()


## A fade no mode covers, made by a script: a step from full to nothing at 50 ticks.
class StepFade extends FadeProfile:
	func value_at(ticks: float) -> float:
		return 1.0 if ticks < 50.0 else 0.0

	func ends_after() -> int:
		return 50


# Claude 2026-11-09: the C++ store and the GDScript store, given the same calls, give the same answers. Fades of every kind,
# including a drawn curve and a script's own, delays, certainty, forgetting, most aware and target scoring.
func _test_stores_agree() -> void:
	if not ClassDB.class_exists(&"AIMemoryStore"):
		print("  (no C++ library here, so there's no C++ store to compare)")
		return
	var native: Object = ClassDB.instantiate(&"AIMemoryStore")
	var script_store := AIMemoryStoreGD.new()
	var a := await _make_pawn(0, Vector3(0, 0, -5))
	var b := await _make_pawn(0, Vector3(6, 0, -2))
	var c := await _make_pawn(0, Vector3(-3, 0, -9))
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(0.4, 0.8))
	curve.add_point(Vector2(1.0, 0.0))
	var drawn := FadeProfile.new()
	drawn.mode = FadeProfile.Mode.CURVE
	drawn.hold_ticks = 15
	drawn.fade_ticks = 120
	drawn.curve = curve
	var halving := FadeProfile.new()
	halving.mode = FadeProfile.Mode.HALF_LIFE
	halving.hold_ticks = 10
	halving.half_life_ticks = 25
	var step: FadeProfile = StepFade.new()
	var cases := [[drawn, false, halving, false], [step, true, drawn, false], [halving, false, step, true]]
	var worst := 0.0
	var same_choices := true
	for case in cases:
		for store in [native, script_store]:
			store.clear()
			store.configure_fades(case[0], 40, case[1], case[2], 20, case[3], 30)
		for store in [native, script_store]:
			store.record_sighting(a, 0.4, 100, a.global_position)
			store.record_sighting(b, 0.7, 104, b.global_position)
			store.record_sighting(c, 1.0, 108, c.global_position) # certain at once
			store.record_check(a, 110)
			store.record_sighting(a, 0.25, 118, a.global_position) # not in view all along: fades first
			store.add_threat(b, 0.5)
		for tick in range(100, 400, 7):
			for i in native.entry_count():
				worst = maxf(worst, absf(native.awareness_at(i, tick) - script_store.awareness_at(i, tick)))
			same_choices = same_choices and native.most_aware_index(Vector3.ZERO, tick) == script_store.most_aware_index(Vector3.ZERO, tick)
			same_choices = same_choices and native.best_target(Vector3.ZERO, 1.0, 0.5, 1.0, 25.0, 0.1, b.get_instance_id(), 0.2, tick) 					== script_store.best_target(Vector3.ZERO, 1.0, 0.5, 1.0, 25.0, 0.1, b.get_instance_id(), 0.2, tick)
		var forgotten_native: PackedInt64Array = native.forget_old(260)
		var forgotten_script: PackedInt64Array = script_store.forget_old(260)
		forgotten_native.sort()
		forgotten_script.sort()
		same_choices = same_choices and forgotten_native == forgotten_script and native.entry_count() == script_store.entry_count()
	_check(worst < 0.0001, "the C++ and GDScript stores give the same awareness, for curve, half-life and script-made fades (largest difference %.6f)" % worst)
	_check(same_choices, "and the same most aware entry, target and forgotten entries at every tick checked")
	a.free()
	b.free()
	c.free()


# --- Helpers ---


## Sets memory to exactly these two awarenesses at this tick, so the numbers don't drift with fading between steps.
func _remember(memory: AIMemory, first: Pawn, first_awareness: float, second: Pawn, second_awareness: float, tick: int) -> void:
	memory.clear()
	memory.record_sighting(first, first_awareness, tick, first.global_position)
	memory.record_sighting(second, second_awareness, tick, second.global_position)


## A pawn with the default parts, on a team, that never senses or decides on its own unless a test changes that.
func _make_pawn(team: int, at: Vector3, schedule := false) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.team = team
	pawn.position = at
	add_child(pawn)
	if not schedule:
		pawn.ai_context.decision_interval_ticks = NEVER
		pawn.ai_sensing_manager.sense_interval_ticks = NEVER
		pawn.ai_sensing_manager.refresh_interval_ticks = NEVER
	await _ticks(2)
	return pawn


func _make_box(centre: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = centre
	add_child(body)
	return body


## Waits until the condition holds, up to max_ticks. Returns how many ticks it took, or -1.
func _until(condition: Callable, max_ticks: int) -> int:
	for i in max_ticks:
		if condition.call():
			return i
		await get_tree().physics_frame
	return -1


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
