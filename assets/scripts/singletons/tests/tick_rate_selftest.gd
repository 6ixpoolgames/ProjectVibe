## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for the tick rate chosen per match (scaling spec step 6): settings
## counted in ticks are written for 60 a second and last the same time at 30, physics steps at the tick rate, both AI memory stores
## agree at 30, and a goblin notices someone about as fast at 30 as at 60.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/singletons/tests/tick_rate_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


func _ready() -> void:
	print("--- Tick rate self-test ---")
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	_test_conversion()
	_test_same_time()
	_test_stores_agree()
	await _test_noticing()
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_conversion() -> void:
	TickDriver.tick_rate = 60
	_check(TickDriver.ticks_at_rate(8) == 8 and TickDriver.ticks_at_rate(15) == 15, "at 60, the reference rate, settings are used as they are")
	TickDriver.tick_rate = 30
	_check(TickDriver.get_tick_rate() == 30 and Engine.physics_ticks_per_second == 30, "choosing 30 sets the tick rate, and physics follows it")
	_check(TickDriver.ticks_at_rate(8) == 4 and TickDriver.ticks_at_rate(1) == 1 and TickDriver.ticks_at_rate(15) == 8, "at 30: 8 ticks become 4, 1 stays 1 (never 0), 15 becomes 8 (rounded)")
	_check(TickDriver.ticks_at_rate(0) == 0 and TickDriver.ticks_at_rate(-1) == -1, "0 and -1 keep their meanings")
	_check(is_equal_approx(TickDriver.per_tick_at_rate(1.0 / 30.0), 1.0 / 15.0), "an amount per tick doubles at 30, so the amount per second is the same")


## A sample of settings, in seconds at both rates: equal, or within half a tick where they don't divide evenly.
func _test_same_time() -> void:
	var swing := MeleeAttackAbility.new()
	var fade := FadeProfile.new()
	fade.hold_ticks = 30
	fade.fade_ticks = 60
	var seconds := {}
	for rate in [60, 30]:
		TickDriver.tick_rate = rate
		var dt := TickDriver.get_tick_dt()
		seconds[rate] = {
			"swing": swing.duration_ticks() * dt,
			"fade": fade.ends_after() * dt,
			"half way": fade.value_at(60.0 * rate / 60.0),
			"sensing interval": TickDriver.ticks_at_rate(10) * dt,
			"decision interval": TickDriver.ticks_at_rate(15) * dt,
			"rest check": TickDriver.ticks_at_rate(15) * dt,
		}
	var worst := 0.0
	for key in seconds[60]:
		if key == "half way":
			continue
		worst = maxf(worst, absf(seconds[60][key] - seconds[30][key]))
	print("        at 60: %s" % str(seconds[60]))
	print("        at 30: %s" % str(seconds[30]))
	_check(is_equal_approx(seconds[60]["swing"], 0.4) and is_equal_approx(seconds[30]["swing"], 0.4), "the swing lasts 0.4 s at both rates (24 ticks at 60, 12 at 30)")
	_check(is_equal_approx(seconds[60]["half way"], seconds[30]["half way"]), "a fade is as far along one second in at both rates")
	_check(worst <= 0.5 / 30.0 + 0.0001, "every sampled setting lasts the same time at 30 as at 60, within half a tick (largest difference %.3f s)" % worst)
	swing.free()


## The C++ and GDScript memory stores fade exactly alike at 30.
func _test_stores_agree() -> void:
	if not ClassDB.class_exists(&"AIMemoryStore"):
		print("  (no C++ library here, so there's no C++ store to compare)")
		return
	TickDriver.tick_rate = 30
	var fade := FadeProfile.new()
	fade.mode = FadeProfile.Mode.LINEAR
	fade.hold_ticks = 20
	fade.fade_ticks = 90
	var native: Object = ClassDB.instantiate(&"AIMemoryStore")
	native.set_tick_rate(30)
	var script_store := AIMemoryStoreGD.new()
	var a := Node3D.new()
	add_child(a)
	for store in [native, script_store]:
		store.configure_fades(fade, TickDriver.ticks_at_rate(60), false, fade, 0, false, TickDriver.ticks_at_rate(30))
		store.record_sighting(a, 0.6, 100, Vector3.ZERO)
		store.record_check(a, 101)
	var worst := 0.0
	for tick in range(100, 260, 3):
		worst = maxf(worst, absf(native.awareness_at(0, tick) - script_store.awareness_at(0, tick)))
	_check(worst < 0.000001, "at 30, the C++ and GDScript stores fade exactly alike (largest difference %.7f)" % worst)
	a.free()


## A pawn of another team stands in front of a goblin: it becomes certain about as fast at 30 as at 60.
func _test_noticing() -> void:
	var took := {}
	for rate in [60, 30]:
		TickDriver.tick_rate = rate
		var goblin: Pawn = load(PAWN_SCENE).instantiate()
		goblin.name = "Goblin"
		goblin.team = 1
		goblin.position = Vector3(0, 0.1, 0) # faces -Z
		var other: Pawn = load(PAWN_SCENE).instantiate()
		other.name = "Other"
		other.team = 0
		other.position = Vector3(0, 0.1, -12)
		add_child(goblin)
		add_child(other)
		var started := TickDriver.tick
		var certain_at := -1
		for i in 200:
			await get_tree().physics_frame
			var index: int = goblin.ai_memory.find(other)
			if index >= 0 and goblin.ai_memory.is_certain_at(index):
				certain_at = TickDriver.tick
				break
		took[rate] = float(certain_at - started) / rate if certain_at >= 0 else -1.0
		goblin.free()
		other.free()
		await get_tree().physics_frame
	print("        certain after %.3f s at 60, %.3f s at 30" % [took[60], took[30]])
	_check(took[60] > 0.0 and took[30] > 0.0 and absf(took[60] - took[30]) <= 0.2, "a goblin becomes certain of someone in front of it about as fast at 30 as at 60 (within 0.2 s: a sensing pass is 1/6 s)")


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
