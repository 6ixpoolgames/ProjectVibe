# Written by Claude (claude-opus-5-5), 2026-11-24: headless self-test for the pawn redesign's foundations (pawn spec 16.10, step 1):
# the tick scheduler's order and timing, DeterministicRandom's ranges and repeatability, entity numbers, and the seconds helpers.
# Exits 0 on success, 1 on failure. Run from the project folder:
#   godot --headless --path . "res://assets/scripts/singletons/tests/foundations_selftest.tscn"
extends SelfTest


func _ready() -> void:
	print("--- Foundations self-test ---")
	_test_scheduler_order()
	await _test_scheduler_on_the_driver()
	_test_random()
	_test_entity_numbers()
	_check(TickDriver.reference_ticks(0.5) == 30 and is_equal_approx(TickDriver.reference_seconds(90), 1.5), "the seconds helpers: 0.5 s is 30 ticks at 60 a second, 90 ticks is 1.5 s")
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_scheduler_order() -> void:
	var scheduler := TickScheduler.new()
	var ran: Array = []
	scheduler.book(5, func() -> void: ran.append("late order 1"), TickScheduler.Point.BEFORE_TICK, 1)
	scheduler.book(5, func() -> void: ran.append("first booked, order 2"), TickScheduler.Point.BEFORE_TICK, 2)
	scheduler.book(5, func() -> void: ran.append("second booked, order 2"), TickScheduler.Point.BEFORE_TICK, 2)
	scheduler.book(4, func() -> void: ran.append("earlier tick"), TickScheduler.Point.BEFORE_TICK, 9)
	scheduler.book(5, func() -> void: ran.append("other point"), TickScheduler.Point.AFTER_SIMULATE)
	scheduler.book(6, func() -> void: ran.append("not due"))
	_check(scheduler.run_due(TickScheduler.Point.BEFORE_TICK, 3) == 0 and ran.is_empty(), "nothing runs before its tick")
	_check(scheduler.run_due(TickScheduler.Point.BEFORE_TICK, 5) == 4, "everything due at a point runs, a passed tick included")
	_check(ran == ["earlier tick", "late order 1", "first booked, order 2", "second booked, order 2"], "in order: tick, then order number, then booking order (%s)" % str(ran))
	_check(scheduler.count(TickScheduler.Point.BEFORE_TICK) == 1 and scheduler.count(TickScheduler.Point.AFTER_SIMULATE) == 1, "the other point and later ticks wait")
	var gone := Node.new()
	scheduler.book(6, gone.queue_free) # a bound method of an object that's freed before it's due
	gone.free()
	_check(scheduler.run_due(TickScheduler.Point.BEFORE_TICK, 6) == 2 and ran.back() == "not due", "an action whose object was freed is skipped")
	var inner: Array = []
	scheduler.book(7, func() -> void: scheduler.book(7, func() -> void: inner.append(1)))
	scheduler.run_due(TickScheduler.Point.BEFORE_TICK, 7)
	_check(inner.is_empty() and scheduler.count(TickScheduler.Point.BEFORE_TICK) == 1, "an action booked while others run waits for the next run")
	scheduler.clear()
	_check(scheduler.count(TickScheduler.Point.BEFORE_TICK) == 0, "clear() drops every booking")


func _test_scheduler_on_the_driver() -> void:
	var seen := {"before": -1, "after": -1, "in_tick": true}
	var start: int = TickDriver.tick
	TickDriver.scheduler.book(start + 2, func() -> void:
		seen["before"] = TickDriver.tick + 1 # the tick about to run
		seen["in_tick"] = TickDriver.is_in_tick())
	TickDriver.scheduler.book(start + 2, func() -> void: seen["after"] = TickDriver.tick, TickScheduler.Point.AFTER_SIMULATE)
	while TickDriver.tick < start + 3:
		await get_tree().physics_frame
	_check(seen["before"] == start + 2 and not seen["in_tick"], "the tick driver runs before-tick actions just before their tick, between ticks")
	_check(seen["after"] == start + 2, "and after-simulate actions during their tick")


func _test_random() -> void:
	var in_range := true
	var ints_cover := {}
	for tick in 2000:
		var unit := DeterministicRandom.unit(7, tick, 3)
		var signed := DeterministicRandom.signed(7, tick, 3)
		var between := DeterministicRandom.float_range(2.0, 4.0, 7, tick)
		var whole := DeterministicRandom.int_range(-2, 2, 7, tick)
		in_range = in_range and unit >= 0.0 and unit < 1.0 and signed >= -1.0 and signed < 1.0 and between >= 2.0 and between < 4.0 and whole >= -2 and whole <= 2
		ints_cover[whole] = true
	_check(in_range and ints_cover.size() == 5, "unit, signed, float_range and int_range stay in range, and int_range reaches both ends")
	_check(DeterministicRandom.unit(7, 100, 3) == DeterministicRandom.unit(7, 100, 3) and DeterministicRandom.unit(7, 100, 3) != DeterministicRandom.unit(8, 100, 3), "the same key, tick and salt roll the same; another key rolls differently")
	var before := DeterministicRandom.unit(7, 100, 3)
	DeterministicRandom.match_seed = 99
	var seeded := DeterministicRandom.unit(7, 100, 3)
	DeterministicRandom.match_seed = 0
	_check(seeded != before and DeterministicRandom.unit(7, 100, 3) == before, "the match seed changes every roll")
	_check(DeterministicRandom.pick([], 1, 1) == null and DeterministicRandom.pick(["only"], 1, 1) == "only", "pick: null from nothing, the one item from one")


func _test_entity_numbers() -> void:
	var a := Node3D.new()
	var b := Node3D.new()
	a.name = "Same"
	b.name = "Same"
	var left := Node.new()
	var right := Node.new()
	add_child(left)
	add_child(right)
	left.add_child(a)
	right.add_child(b)
	_check(EntityNumber.of(a) != EntityNumber.of(b) and EntityNumber.of(a) == EntityNumber.of(a) and EntityNumber.of(a) >= 0, "two nodes with one name under different parents get different numbers, each the same every time")
	_check(EntityNumber.of(null) == EntityNumber.NONE, "none for null")
	left.free()
	right.free()
	_check(EntityNumber.of(a) == EntityNumber.NONE, "and for a freed node")
