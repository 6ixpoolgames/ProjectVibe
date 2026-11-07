## Written by Claude (claude-opus-5-5), 2026-11-04: headless self-test for the tick driver (TickDriver.gd).
## Checks the rules listed at the top of TickDriver.gd. Exits 0 on success, 1 on failure. Run from the project folder:
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/singletons/tests/tick_driver_selftest.tscn"
extends Node

var _failures := 0
var _log: Array = []


## Has all three phases; writes "<name>:<phase>:<tick>" into the shared log.
class Full extends RefCounted:
	var id: String
	var log: Array
	var dts: Array = []
	var on_simulate: Callable
	func _init(n: String, l: Array) -> void:
		id = n
		log = l
	func _tick_input(_dt: float, t: int) -> void:
		log.append("%s:in:%d" % [id, t])
	func _tick_simulate(dt: float, t: int) -> void:
		dts.append(dt)
		log.append("%s:sim:%d" % [id, t])
		if on_simulate.is_valid():
			on_simulate.call()
	func _tick_record(t: int) -> void:
		log.append("%s:rec:%d" % [id, t])


## Only simulates: must not be asked for the other phases.
class SimOnly extends Node:
	var log: Array
	func _tick_simulate(_dt: float, t: int) -> void:
		log.append("simonly:sim:%d" % t)


func _ready() -> void:
	print("--- Tick driver self-test ---")
	_test_phases_and_order()
	_test_timing()
	_test_registry_changes()
	_test_helpers()
	_test_autoload()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _driver() -> TickDriverSingleton:
	var d := TickDriverSingleton.new()
	d.active = false # the test drives advance()/step() itself
	d.tick_rate = 60
	add_child(d)
	return d


func _test_phases_and_order() -> void:
	var d := _driver()
	_log.clear()
	var a := Full.new("a", _log)
	var b := Full.new("b", _log)
	d.register(b)
	d.register(a, -1) # lower order runs first
	d.before_tick.connect(func(_dt, t): _log.append("before:%d" % t))
	d.after_tick.connect(func(_dt, t): _log.append("after:%d" % t))
	d.step()
	_check(_log == ["before:1", "a:in:1", "b:in:1", "a:sim:1", "b:sim:1", "a:rec:1", "b:rec:1", "after:1"],
		"one tick: before, all inputs, all simulates, all records, after; lower order first")
	_check(d.tick == 1, "tick counter advances")

	var c := Full.new("c", _log)
	d.register(c, -1) # same order as a: registration order decides
	_log.clear()
	d.step()
	_check(_log.slice(1, 4) == ["a:in:2", "c:in:2", "b:in:2"], "equal order keeps registration order")

	d.register(a, 99)
	_check(d.get_participant_count() == 3, "registering twice changes nothing")
	d.unregister(RefCounted.new()) # unknown: no-op, no error

	var s := SimOnly.new()
	s.log = _log
	d.register(s)
	_log.clear()
	d.step()
	_check(_log.has("simonly:sim:3") and _log.filter(func(e): return e.begins_with("simonly")).size() == 1,
		"a participant only gets the phases it implements")
	s.free()
	_log.clear()
	d.step()
	_check(not _log.any(func(e): return e.begins_with("simonly")), "freed participant is skipped, no error")
	d.step()
	_check(d.get_participant_count() == 3, "...and dropped from the registry")
	d.free()


func _test_timing() -> void:
	var d := _driver()
	_log.clear()
	var a := Full.new("a", _log)
	d.register(a)

	d.advance(1.0 / 120.0)
	_check(d.tick == 0, "half a tick of time: no tick yet")
	d.advance(1.0 / 120.0)
	_check(d.tick == 1, "time adds up to a full tick: one tick")
	_check(a.dts.size() == 1 and is_equal_approx(a.dts[0], 1.0 / 60.0), "simulate gets the fixed tick length")

	d.advance(3.0 / 60.0 + 0.0001)
	_check(d.tick == 4, "a long frame runs several ticks")

	d.max_ticks_per_frame = 4
	d.advance(10.0 / 60.0 + 0.0001)
	_check(d.tick == 8, "max_ticks_per_frame caps ticks in one frame")
	_check(d.dropped_ticks == 6, "the rest is dropped and counted (no spiral of death)")
	d.advance(0.0)
	_check(d.tick == 8, "dropped time doesn't come back next frame")

	d.tick_factor = 0.5
	for i in 4:
		d.advance(1.0 / 60.0)
	_check(d.tick == 10, "tick_factor 0.5: half as many ticks")
	d.tick_factor = 1.0

	var loops := [0, 0]
	d.before_tick_loop.connect(func(): loops[0] += 1)
	d.after_tick_loop.connect(func(): loops[1] += 1)
	d.advance(0.001)
	_check(loops == [0, 0], "no tick this frame: no loop signals")
	d.advance(2.0 / 60.0)
	_check(loops == [1, 1], "loop signals once per frame, around all of that frame's ticks")

	var t := d.tick
	d.active = true # pausing is about _physics_process; advance() is the manual path
	d.active = false
	_check(d.tick == t, "toggling active doesn't run ticks by itself")
	d.free()


func _test_registry_changes() -> void:
	var d := _driver()
	_log.clear()
	var a := Full.new("a", _log)
	var b := Full.new("b", _log)
	var late := Full.new("late", _log)
	d.register(a)
	d.register(b)
	a.on_simulate = func():
		d.unregister(b)
		d.register(late)
	d.step()
	_check(not _log.has("b:sim:1") and not _log.has("b:rec:1"), "unregistered mid-tick: no further calls that tick")
	_check(_log.has("b:in:1"), "...calls before the unregister already happened")
	_check(not _log.any(func(e): return e.begins_with("late")), "registered mid-tick: not called that tick")
	a.on_simulate = Callable()
	_log.clear()
	d.step()
	_check(_log.has("late:sim:2") and not _log.any(func(e): return e.begins_with("b:")), "...from the next tick: the new one runs, the removed one doesn't")
	d.free()


func _test_helpers() -> void:
	var d := _driver()
	_check(d.seconds_to_ticks(0.15) == 9, "0.15 s = 9 ticks at 60")
	_check(d.seconds_to_ticks(0.001) == 1, "any time above zero is at least one tick")
	_check(d.seconds_to_ticks(0.0) == 0 and d.seconds_to_ticks(-1.0) == 0, "zero or negative seconds: 0 ticks")
	_check(d.seconds_to_ticks(1.0) == 60, "1 s = 60 ticks (no rounding up past exact values)")
	_check(is_equal_approx(d.ticks_to_seconds(30), 0.5), "30 ticks = 0.5 s")
	_check(not d.is_resimulating(), "not resimulating (no rollback yet)")
	_check(d.is_authority(), "offline: authority")
	d.tick_rate = 30
	_check(d.get_tick_rate() == 30 and is_equal_approx(d.get_physics_factor(), Engine.physics_ticks_per_second / 30.0),
		"tick_rate setting and physics_factor")
	d.tick_rate = 0
	_check(d.get_tick_rate() == Engine.physics_ticks_per_second, "tick_rate 0: uses the physics rate")
	var f := d.get_interpolation_fraction()
	_check(f >= 0.0 and f <= 1.0, "interpolation fraction stays within 0..1")
	d.free()


func _test_autoload() -> void:
	var n = get_node_or_null("/root/TickDriver")
	_check(n is TickDriverSingleton, "TickDriver autoload exists")
	if n:
		_check(n.get_tick_rate() == Engine.physics_ticks_per_second, "autoload defaults to one tick per physics frame")


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
