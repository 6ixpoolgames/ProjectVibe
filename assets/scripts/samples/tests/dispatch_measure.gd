## Written by Claude (claude-opus-5-5), 2026-11-19: measures what calling things costs, for the state store refactor (state store spec
## section 13, "dispatch cost"). Not pass/fail: it prints microseconds. The question it answers: how much of a tick is the tick driver
## calling each participant one by one, against one loop doing the same work, and what a call from GDScript into C++ costs.
##
## Run from the project folder, headless:
##   godot --headless --path . "res://assets/scripts/samples/tests/dispatch_measure.tscn" -- --pawns=300 --ticks=200
## It registers three do-nothing participants per pawn with TickDriver, shaped like today's (a pawn: input and simulate; a recorder:
## capture and record; a network entity: input and record), and times TickDriver.step(). Then the same number of calls in a plain loop,
## a loop with no call at all, calls into a C++ object (typed and untyped), and the two ways of reading a property.
## Test code: it drives the TickDriver autoload directly (docs/TEST_AND_DEBUG_CODE.md).
extends Node

var _pawns := 300
var _ticks := 200


class FakePawn extends Node:
	var counter := 0
	func _tick_input(_dt: float, _tick: int) -> void:
		pass
	func _tick_simulate(_dt: float, _tick: int) -> void:
		pass
	func work() -> void:
		counter += 1


class FakeRecorder extends Node:
	func _tick_capture_input(_tick: int) -> void:
		pass
	func _tick_record(_tick: int) -> void:
		pass


class FakeEntity extends Node:
	func _tick_input(_dt: float, _tick: int) -> void:
		pass
	func _tick_record(_tick: int) -> void:
		pass


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pawns="):
			_pawns = int(arg.trim_prefix("--pawns="))
		elif arg.begins_with("--ticks="):
			_ticks = int(arg.trim_prefix("--ticks="))
	_run.call_deferred()


func _run() -> void:
	print("[dispatch] pawns %d, ticks %d, debug build %s" % [_pawns, _ticks, OS.is_debug_build()])
	TickDriver.active = false # only step() ticks
	var holder := Node.new()
	add_child(holder)
	var pawns: Array[FakePawn] = []
	for i in _pawns:
		var pawn := FakePawn.new()
		var recorder := FakeRecorder.new()
		var entity := FakeEntity.new()
		holder.add_child(pawn)
		holder.add_child(recorder)
		holder.add_child(entity)
		TickDriver.register(pawn)
		TickDriver.register(recorder)
		TickDriver.register(entity)
		pawns.append(pawn)
	TickDriver.step() # builds the phase lists once
	# 1. The tick driver calling 3 participants per pawn, 6 calls per pawn per tick.
	var started := Time.get_ticks_usec()
	for i in _ticks:
		TickDriver.step()
	var driver_usec := float(Time.get_ticks_usec() - started) / _ticks
	_row("tick driver, empty participants (a tick)", driver_usec, _pawns * 6)
	for pawn in pawns:
		TickDriver.unregister(pawn)
	for child in holder.get_children():
		TickDriver.unregister(child)
	TickDriver.step()
	# 2. The same number of method calls in a plain loop (what a batched GDScript pass still pays).
	started = Time.get_ticks_usec()
	for i in _ticks:
		for round in 6:
			for pawn in pawns:
				pawn.work()
	_row("plain loop, a method call each (a tick)", float(Time.get_ticks_usec() - started) / _ticks, _pawns * 6)
	# 3. A loop over packed data with no call (what a batched pass doing its work inline pays).
	var values := PackedFloat64Array()
	values.resize(_pawns)
	started = Time.get_ticks_usec()
	for i in _ticks:
		for round in 6:
			for j in _pawns:
				values[j] += 1.0
	_row("plain loop, inline work, no call (a tick)", float(Time.get_ticks_usec() - started) / _ticks, _pawns * 6)
	# 4. Calls into C++: a cheap getter on a C++ object, untyped (Variant dispatch) and typed.
	if ClassDB.class_exists(&"PawnTable"):
		var untyped: Object = ClassDB.instantiate(&"PawnTable")
		var total := 0
		started = Time.get_ticks_usec()
		for i in _ticks:
			for j in _pawns:
				total += untyped.get_count()
		_row("C++ call through an untyped Object (a tick)", float(Time.get_ticks_usec() - started) / _ticks, _pawns)
		# Typed, so GDScript can call it directly: compiled from source here, since naming the class in this file would stop it
		# parsing where the library isn't loaded.
		var typed_script := GDScript.new()
		typed_script.source_code = "extends RefCounted\nfunc run(table: PawnTable, ticks: int, pawns: int) -> int:\n\tvar total := 0\n\tfor i in ticks:\n\t\tfor j in pawns:\n\t\t\ttotal += table.get_count()\n\treturn total\n"
		if typed_script.reload() == OK:
			var runner: Object = typed_script.new()
			started = Time.get_ticks_usec()
			total += runner.run(untyped, _ticks, _pawns)
			_row("C++ call, typed (a tick)", float(Time.get_ticks_usec() - started) / _ticks, _pawns)
	else:
		print("[dispatch] no C++ library: C++ call rows skipped")
	# 5. Reading a property: directly, by name, and by NodePath (the recorder's GDScript path).
	var probe: FakePawn = pawns[0]
	var path := NodePath(":counter")
	var sum := 0
	started = Time.get_ticks_usec()
	for i in _ticks:
		for j in _pawns:
			sum += probe.counter
	_row("property read, direct (a tick)", float(Time.get_ticks_usec() - started) / _ticks, _pawns)
	started = Time.get_ticks_usec()
	for i in _ticks:
		for j in _pawns:
			sum += probe.get(&"counter")
	_row("property read, get() by name (a tick)", float(Time.get_ticks_usec() - started) / _ticks, _pawns)
	started = Time.get_ticks_usec()
	for i in _ticks:
		for j in _pawns:
			sum += probe.get_indexed(path)
	_row("property read, get_indexed() (a tick)", float(Time.get_ticks_usec() - started) / _ticks, _pawns)
	print("[dispatch] done")
	get_tree().quit()


func _row(label: String, usec_per_tick: float, calls_per_tick: int) -> void:
	print("[dispatch] %-46s %9.1f us a tick  %6.3f us a call  (%d calls)" % [label, usec_per_tick, usec_per_tick / maxi(calls_per_tick, 1), calls_per_tick])
