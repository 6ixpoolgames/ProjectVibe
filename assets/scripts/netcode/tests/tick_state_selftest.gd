## Written by Claude (claude-opus-5-5), 2026-11-04: headless self-test for rollback (netcode spec build steps 2-3).
## Covers StateEncoding, TickStateComponent and TickDriver.rollback, first with plain scripted entities, then with a real
## CharacterBody3D walking, jumping and hitting a wall under real physics. The key question: does replaying from a saved
## tick reproduce exactly what happened? No network involved. Exits 0 on success, 1 on failure. Run from the project folder:
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/netcode/tests/tick_state_selftest.tscn"
extends Node

var _failures := 0
var nt: TickDriverSingleton
var _replayed_from_air := false
var _replayed_from_ground := false


## Moves by whatever it's told to want. Its input and simulate are counted, so replays can be seen.
class Mover extends Node3D:
	var want := Vector3.ZERO
	var pos := Vector3.ZERO
	var plan: Callable             # tick -> Vector3
	var input_calls := 0
	var simulate_calls := 0
	var effects := 0
	var replay_ticks: Array = []
	var rolls: Dictionary = {}     # tick -> first roll seen for that tick
	var rolls_repeat := true

	func _tick_input(_dt: float, t: int) -> void:
		input_calls += 1
		want = plan.call(t) if plan.is_valid() else Vector3.ZERO

	func _tick_simulate(dt: float, t: int) -> void:
		simulate_calls += 1
		pos += want * dt
		var driver: TickDriverSingleton = get_node("/root/TickDriver")
		var roll := driver.tick_rng(7).randf()
		if rolls.has(t) and rolls[t] != roll:
			rolls_repeat = false
		rolls[t] = roll
		if driver.is_resimulating():
			replay_ticks.append(driver.tick)
		else:
			effects += 1


## Claude 2026-11-09: one property of every kind the recorder handles, each changing by awkward amounts every tick, for comparing the
## C++ and GDScript recording paths. It counts its own ticks, so two runs starting at different tick numbers do the same thing.
class RecordedThing extends Node3D:
	var n := 0
	var pos := Vector3.ZERO           # auto: vector3_mm
	var near := Vector3.ZERO          # vector3_cm
	var heading := 0.0                # angle_u16, wrapping past PI
	var dir := 0.0                    # angle_byte
	var speed := 0.0                  # auto: float
	var count := 0                    # auto: raw
	var flag := false                 # auto: raw
	var trail: Array = []             # auto: raw, copied deeply
	var flat := Vector2.ZERO          # auto: vector2_mm

	func _tick_simulate(_dt: float, _t: int) -> void:
		n += 1
		pos += Vector3(0.0123457 * n, -0.0004999, 0.3333333)
		near += Vector3(0.00499, 0.015, -0.0051)
		heading += 0.7123
		dir -= 0.3001
		speed = speed * 1.01 + 0.1234567
		count += 3
		flag = not flag
		trail.append([n])
		if trail.size() > 3:
			trail.pop_front()
		flat += Vector2(0.00049, -0.00151)
		rotation.y += 0.0512345
		var part := get_node_or_null("Part") # one check frees it on purpose
		if part:
			part.set("level", part.get("level") + 0.0617)


## Simulates, but has no rollback state: must not be replayed.
class Bystander extends Node:
	var simulate_calls := 0

	func _tick_simulate(_dt: float, _t: int) -> void:
		simulate_calls += 1


## Lists and dictionaries in its state, changed every tick.
class BufferEntity extends Node:
	var buffer: Array = []
	var table: Dictionary = {"count": 0}

	func _tick_simulate(_dt: float, t: int) -> void:
		buffer.append(t)
		table["count"] += 1


## Holds an Object, which can't be copied into the history.
class ObjectHolder extends Node:
	var thing: RefCounted = RefCounted.new()


## Sets its value in _ready, which runs after its child component's _ready.
class ReadySetter extends Node:
	var late_value = null

	func _ready() -> void:
		late_value = Vector3(1.23456, 0, 0)


## State that can't be expressed as a property list.
class CustomSaver extends Node:
	var bag := {"count": 0}

	func _tick_simulate(_dt: float, _t: int) -> void:
		bag["count"] += 1

	func save_state() -> Dictionary:
		return bag.duplicate()

	func load_state(d: Dictionary) -> void:
		bag = d # keeps what it's given; the component hands it a copy


## Claude 2026-11-04: moved from outside, like a door. Counts what must not run while it follows the server.
class Follower extends Node3D:
	var simulate_calls := 0
	var loaded_calls := 0

	func _tick_simulate(_dt: float, _t: int) -> void:
		simulate_calls += 1

	func _on_state_loaded(_t: int) -> void:
		loaded_calls += 1


## Claude 2026-11-04: the same, with a velocity to estimate from.
class MovingFollower extends Follower:
	var velocity := Vector3.ZERO


## Claude 2026-11-04: the 2D version.
class MovingFollower2D extends Node2D:
	var velocity := Vector2.ZERO


## Claude 2026-11-04: a part below the entity that holds its velocity, as the motor will.
class MotorPart extends Node:
	var velocity := Vector3.ZERO


## Claude 2026-11-04: notes what its load hook could see: whether the replay flag was on, and another entity's value.
class LoadHookEntity extends Node:
	var value := 0
	var other: LoadHookEntity = null
	var flag_during_load := false
	var other_value_during_load := -1

	func _on_state_loaded(_t: int) -> void:
		flag_during_load = (get_node("/root/TickDriver") as TickDriverSingleton).is_resimulating()
		if other:
			other_value_during_load = other.value


## Claude 2026-11-04: predicted, and notes where another entity is whenever it simulates.
class Watcher extends Node:
	var target: Node
	var count := 0
	var seen: Dictionary = {}

	func _tick_simulate(_dt: float, t: int) -> void:
		count += 1
		seen[t] = target.position


## A real body with a scripted input, walking, jumping and pushing into a wall for the physics part.
class ScriptedPawn extends TickSamplePawn:
	var start_tick := -1 # stands still until set
	var wall_x_sign := 1.0
	var wall_ticks: Dictionary = {} # ticks on which the body was touching a wall
	var lowest_grounded_y := 0.0    # how far it ever sank while on the floor, which should be not at all
	var body_bump_ticks: Dictionary = {} # ticks on which it pushed against another pawn
	var along_amount := 0.6         # how hard it pushes along the wall; different values give truly different paths
	var jump_every := 47            # ticks between jumps
	var simulate_calls := 0
	var seek: Node3D = null         # Claude 2026-11-04: when set, walks toward this instead of the wall
	var change_every := 0           # Claude 2026-11-04: when above 0, adds a random new direction every this many ticks

	func _tick_input(_dt: float, t: int) -> void:
		if start_tick < 0:
			move_dir = Vector3.ZERO
			wants_sprint = false
			wants_jump = false
			return
		var i := t - start_tick
		wants_sprint = i % 90 > 60
		wants_jump = i % jump_every == 20 % jump_every
		# Mostly toward the wall, sliding along it, with short steps back.
		var toward := i % 40 < 32
		var along := along_amount if i % 200 < 100 else -along_amount
		move_dir = Vector3((1.0 if toward else -1.0) * wall_x_sign, 0.0, along)
		if seek: # Claude 2026-11-04: keeps two pawns in contact while one of them is hard to guess
			var to_other := seek.position - position
			to_other.y = 0.0
			move_dir = to_other.normalized()
		if change_every > 0:
			var change := RandomNumberGenerator.new()
			change.seed = hash(Vector2i(floori(float(i) / change_every), 77))
			var angle := change.randf() * TAU
			move_dir = (move_dir * 0.7 + Vector3(cos(angle), 0.0, sin(angle))).normalized()
			wants_sprint = change.randf() > 0.7

	func _tick_simulate(dt: float, t: int) -> void:
		super(dt, t)
		simulate_calls += 1
		if not _is_resimulating():
			if is_on_wall():
				wall_ticks[t] = true
			if grounded:
				lowest_grounded_y = minf(lowest_grounded_y, position.y)
			for c in get_slide_collision_count():
				if get_slide_collision(c).get_collider() is CharacterBody3D:
					body_bump_ticks[t] = true

	func _is_resimulating() -> bool:
		return _driver != null and _driver.is_resimulating()


func _ready() -> void:
	print("--- Tick state and rollback self-test ---")
	nt = get_node("/root/TickDriver")
	nt.active = false # the plain tests drive ticks by hand
	# Claude 2026-11-09: -- --gdscript-record runs every test here on the GDScript recording path instead of C++.
	if OS.get_cmdline_user_args().has("--gdscript-record"):
		TickStateComponent.use_native = false
		print("        (recording in GDScript)")
	_test_encodings()
	_test_native_recording() # Claude 2026-11-09
	_test_declarations()
	_test_capture()
	_test_rollback()
	_test_rollback_timing()
	_test_custom_state()
	_test_containers()
	_test_late_and_removed_nodes()
	_test_follow_server()
	# Different pushes and jump timings, because a path that only grazes the wall hid most of what's below.
	await _test_real_body(0.6, 47)
	await _test_real_body(0.6, 31)
	await _test_real_body(0.25, 47)
	_check(_replayed_from_air and _replayed_from_ground, "real body: across the paths, replays started from both grounded and airborne ticks")
	await _test_two_bodies()
	await _test_uneven_frames()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_encodings() -> void:
	var q: Vector3 = StateEncoding.quantize(Vector3(1.23456, -0.0004, 2.0), StateEncoding.VECTOR3_MM)
	_check(q.is_equal_approx(Vector3(1.235, 0.0, 2.0)), "vector3_mm rounds to 1 mm")
	_check(StateEncoding.quantize(q, StateEncoding.VECTOR3_MM) == q, "rounding a rounded value changes nothing")
	var a: float = StateEncoding.quantize(PI + 0.5, StateEncoding.ANGLE_U16)
	_check(a < 0.0 and absf(angle_difference(a, PI + 0.5)) < 0.001, "angles wrap into -PI..PI, same direction")
	_check(StateEncoding.quantize(a, StateEncoding.ANGLE_U16) == a, "...and rounding them twice changes nothing")
	_check(StateEncoding.resolve(StateEncoding.AUTO, Vector3.ZERO) == StateEncoding.VECTOR3_MM, "auto: Vector3 is vector3_mm")
	_check(StateEncoding.resolve(StateEncoding.AUTO, 1.0) == StateEncoding.FLOAT, "auto: float is float")
	_check(StateEncoding.resolve(StateEncoding.AUTO, true) == StateEncoding.RAW, "auto: bool is raw")
	_check(StateEncoding.quantize(5, StateEncoding.VECTOR3_MM) == 5, "encoding that doesn't fit the type: unchanged")
	_check(StateEncoding.nearly_equal(Vector3(1, 0, 0), Vector3(1.001, 0, 0), StateEncoding.VECTOR3_MM), "one step apart counts as equal")
	_check(not StateEncoding.nearly_equal(Vector3(1, 0, 0), Vector3(1.002, 0, 0), StateEncoding.VECTOR3_MM), "two steps apart doesn't")
	_check(StateEncoding.nearly_equal(PI - 0.00001, -PI + 0.00001, StateEncoding.ANGLE_U16), "angles compare across the wrap")

	# Engine properties store 32-bit floats. A rounded angle must read back unchanged, or it's rewritten every tick.
	var spinner := Node3D.new()
	spinner.rotation.y = 1.2345678
	var rounded: float = StateEncoding.quantize(spinner.rotation.y, StateEncoding.ANGLE_U16)
	spinner.rotation.y = rounded
	_check(StateEncoding.quantize(spinner.rotation.y, StateEncoding.ANGLE_U16) == spinner.rotation.y, "a rounded angle reads back unchanged from rotation, so it isn't rewritten")
	spinner.free()
	var original := [1, [2]]
	var copied: Array = StateEncoding.copy_value(original)
	copied[1][0] = 9
	_check(original[1][0] == 2, "copy_value copies nested Arrays")

	# The reason positions aren't in cm: rounding every tick stops slow things from moving at all.
	var slow_mm := _creep(0.2, StateEncoding.VECTOR3_MM)
	var slow_cm := _creep(0.2, StateEncoding.VECTOR3_CM)
	print("        0.2 m/s for 1 s, rounded every tick: %.3f m in mm, %.3f m in cm" % [slow_mm, slow_cm])
	_check(absf(slow_mm - 0.2) < 0.03, "1 mm: 0.2 m/s moves about 0.2 m in a second")
	_check(slow_cm == 0.0, "1 cm would stall it completely")


## Claude 2026-11-09: the C++ recorder (TickStateRecorder) against GDScript. First the rounding on its own, value by value, then whole
## recordings of the same entity both ways, then the history interval (every Nth tick, or never) on both paths.
func _test_native_recording() -> void:
	if not ClassDB.class_exists(&"TickStateRecorder"):
		print("        no C++ library here: only the GDScript path is tested")
		return
	var default_native := TickStateComponent.use_native
	# Rounding: thousands of values, with the awkward ones on purpose: half steps, the wrap at PI, negatives, wrong types.
	var recorder: Object = ClassDB.instantiate(&"TickStateRecorder")
	var pick := RandomNumberGenerator.new()
	pick.seed = 2026
	var values: Array = [PI, -PI, PI + 0.000001, -PI - 0.000001, TAU, 0.0, -0.0, 5, true, "text", Vector3.ZERO, null]
	for k in range(-40, 40):
		values.append(k * 0.001 + 0.0005) # exactly half a millimetre: which way it rounds must match
		values.append(Vector3(k * 0.001 + 0.0005, k * 0.01 + 0.005, -k * 0.0015))
		values.append(Vector2(k * 0.001 + 0.0005, -k * 0.001 - 0.0005))
		values.append(k * StateEncoding.U16_STEP * 0.5)
		values.append(k * StateEncoding.BYTE_STEP * 0.5 + PI)
	for i in 4000:
		values.append(pick.randf_range(-20.0, 20.0))
		values.append(Vector3(pick.randf_range(-1000, 1000), pick.randf_range(-5, 5), pick.randf_range(-0.01, 0.01)))
		values.append(Vector2(pick.randf_range(-1000, 1000), pick.randf_range(-0.002, 0.002)))
	var encodings: Array[StringName] = [StateEncoding.VECTOR3_MM, StateEncoding.VECTOR2_MM, StateEncoding.VECTOR3_CM, StateEncoding.ANGLE_U16, StateEncoding.ANGLE_BYTE, StateEncoding.FLOAT, StateEncoding.RAW]
	var compared := 0
	var different: Array = []
	for value in values:
		for encoding in encodings:
			var by_gdscript: Variant = StateEncoding.quantize(value, encoding)
			var by_cpp: Variant = recorder.quantize(value, encoding)
			compared += 1
			# typeof catches a value that comes back as another type, which == alone might let through (5 == 5.0).
			if typeof(by_cpp) != typeof(by_gdscript) or by_cpp != by_gdscript:
				if different.size() < 5:
					different.append("%s %s: %s vs %s" % [encoding, value, by_gdscript, by_cpp])
	_check(different.is_empty(), "C++ rounding gives exactly GDScript's values, %d values and encodings compared %s" % [compared, str(different)])

	# Whole recordings: the same entity, recorded by each path, saves exactly the same states and ends up exactly the same.
	var native := _record_thing(true, 1)
	var gdscript := _record_thing(false, 1)
	_check(native["fast"] and not gdscript["fast"], "the C++ path really recorded the first run, and GDScript the second")
	_check(native["saved"] == gdscript["saved"] and native["saved"].size() == 40, "C++ and GDScript save exactly the same state, tick by tick (%d ticks, %d entries each)" % [native["saved"].size(), native["saved"][0].size()])
	_check(native["final"] == gdscript["final"], "and leave the entity exactly the same")
	var first_tick: Dictionary = native["saved"][0]
	_check(first_tick["trail"] == [[1]] and native["saved"][2]["trail"] == [[1], [2], [3]], "containers are copied, so each tick keeps its own (%s, %s)" % [first_tick["trail"], native["saved"][2]["trail"]])

	# The history interval: every 2nd tick saved, or none; values are rounded every tick either way. Both paths.
	for use_cpp in [true, false]:
		var path := "C++" if use_cpp else "GDScript"
		var every_second := _record_thing(use_cpp, 2)
		_check(every_second["kept_ticks_ok"], "%s: history every 2nd tick: only ticks that are multiples of 2 are saved" % path)
		_check(every_second["final"] == native["final"], "%s: and the entity ends up exactly as when every tick is saved" % path)
		var never := _record_thing(use_cpp, 0)
		_check(never["saved_count"] == 0 and never["final"] == native["final"], "%s: history never: nothing is saved, and values are still rounded every tick (the same end state)" % path)

	# A node that goes away mid-run: the C++ path hands over to GDScript, which skips that entry, with no error.
	TickStateComponent.use_native = true
	var thing := _make_recorded_thing(1)
	var state: TickStateComponent = thing.get_node("TickState")
	for i in 3:
		nt.step()
	var was_fast: bool = state._recorder_ready
	var part := thing.get_node("Part")
	thing.remove_child(part)
	part.free()
	nt.step()
	var saved_after := state.get_state(nt.tick)
	_check(was_fast and not state._recorder_ready and saved_after.has("pos") and not saved_after.has("Part:level"), "a freed node: C++ hands over to GDScript, which saves the rest and skips that entry")
	thing.free()
	TickStateComponent.use_native = default_native


# Claude 2026-11-09: a RecordedThing with its Part and a TickStateComponent listing every kind of entry.
func _make_recorded_thing(interval: int) -> RecordedThing:
	var thing := RecordedThing.new()
	thing.name = "RecordedThing"
	var part := Node.new()
	part.name = "Part"
	# GDScript note: a plain Node has no "level" property, so the part gets a tiny script that declares one.
	var script := GDScript.new()
	script.source_code = "extends Node\nvar level := 0.0\n"
	script.reload()
	part.set_script(script)
	thing.add_child(part)
	var state := TickStateComponent.new()
	state.name = "TickState"
	state.state_properties = ["pos", "near @vector3_cm", "heading @angle_u16", "dir @angle_byte", "speed", "count", "flag", "trail", "flat", ":rotation:y @angle_u16", "Part:level"]
	state.history_interval_ticks = interval
	thing.add_child(state)
	add_child(thing)
	nt.register(thing) # so its _tick_simulate runs
	return thing


# Claude 2026-11-09: records a RecordedThing for 40 ticks on one path, and returns what it saved (by its own tick count), how it ended,
# and whether the C++ path held the list.
func _record_thing(use_cpp: bool, interval: int) -> Dictionary:
	var default_native := TickStateComponent.use_native
	TickStateComponent.use_native = use_cpp
	var thing := _make_recorded_thing(interval)
	var state: TickStateComponent = thing.get_node("TickState")
	var saved: Array = []
	var saved_count := 0
	var kept_ticks_ok := true
	for i in 40:
		nt.step()
		var kept := state.has_state(nt.tick)
		if kept:
			saved_count += 1
			saved.append(state.get_state(nt.tick))
		if interval > 0 and kept != (nt.tick % interval == 0):
			kept_ticks_ok = false
	var result := {
		"saved": saved,
		"saved_count": saved_count,
		"kept_ticks_ok": kept_ticks_ok,
		"fast": state._recorder_ready,
		"final": [thing.pos, thing.near, thing.heading, thing.dir, thing.speed, thing.count, thing.flag, thing.trail, thing.flat, thing.rotation.y, thing.get_node("Part").get("level")],
	}
	thing.free()
	TickStateComponent.use_native = default_native
	return result


func _creep(speed: float, encoding: StringName) -> float:
	var p := Vector3.ZERO
	for i in 60:
		p = StateEncoding.quantize(p + Vector3(speed / 60.0, 0, 0), encoding)
	return p.x


func _test_declarations() -> void:
	var root := Node3D.new()
	root.name = "DeclRoot"
	var child := Mover.new()
	child.name = "Child"
	root.add_child(child)
	var s := TickStateComponent.new()
	s.state_properties = ["position", ":rotation:y @angle_u16", "Child:pos", "no_such_property", "Missing:thing", "rotation:y", "scale @nonsense", " "]
	s.input_properties = ["Child:want"]
	root.add_child(s)
	add_child(root)

	nt.step()
	var saved := s.get_state(nt.tick)
	_check(saved.has("position") and saved.has(":rotation:y") and saved.has("Child:pos"), "good entries work: property, part of a property, property on a child")
	_check(not saved.has("no_such_property") and not saved.has("Missing:thing") and not saved.has("rotation:y"), "bad entries are skipped with a warning, no error")
	_check(saved.has("scale"), "unknown encoding falls back to auto")
	_check(s.get_schema().has("state :rotation:y @angle_u16") and s.get_schema().has("input Child:want"), "schema lists entries with kind and encoding")
	root.free()

	var empty_root := Mover.new()
	var empty := TickStateComponent.new()
	empty_root.add_child(empty)
	add_child(empty_root)
	nt.step()
	_check(empty.get_state(nt.tick).is_empty(), "no lists: harmless, nothing saved")
	_check(not nt.rollback(nt.tick), "no lists: not predicted, so no rollback")
	empty_root.free()


func _test_capture() -> void:
	var m := _mover()
	var s: TickStateComponent = m.get_child(0)
	m.plan = func(_t): return Vector3(1.23456, 0, 0)
	nt.step()
	_check(m.want.x == StateEncoding.quantize(m.want, StateEncoding.VECTOR3_MM).x and is_equal_approx(m.want.x, 1.235), "input is rounded before the simulation uses it")
	_check(s.get_input(nt.tick)["want"] == m.want, "input saved for the tick")
	_check(is_equal_approx(s.get_state(nt.tick)["pos"].x, m.pos.x), "state saved for the tick, rounded")
	var first := nt.tick
	for i in 70:
		nt.step()
	_check(s.get_state(first).is_empty() and s.get_input(first).is_empty(), "older than history_size: gone")
	_check(not s.correct_state(nt.tick + 10, {"pos": Vector3.ONE}) and m.pos != Vector3.ONE, "correcting a tick that hasn't happened: false, nothing changes")
	_check(not s.correct_state(first, {"pos": Vector3.ONE}), "correcting a tick that's gone: false (no replay possible)...")
	_check(m.pos == Vector3.ONE, "...but it snaps to the given values, as the spec says")
	_check(not s.matches_state(first, {}), "comparing with a tick that's gone: false")
	_check(not s.has_state(-1) and s.get_state(-5).is_empty(), "negative ticks: nothing, no error")
	m.free()


func _test_rollback() -> void:
	var m := _mover()
	var s: TickStateComponent = m.get_child(0)
	var other := Bystander.new()
	add_child(other)
	nt.register(other)
	m.plan = func(t): return Vector3(1.0 + (t % 7), 0.0, 0.5)
	var signals: Array = []
	var on_rollback := func(a, b): signals.append([a, b])
	nt.after_rollback.connect(on_rollback)

	for i in 40:
		nt.step()
	var now := nt.tick
	var from := now - 20
	var expected_end: Vector3 = m.pos
	var expected: Dictionary = {}
	for t in range(from, now + 1):
		expected[t] = s.get_state(t)
	var inputs := m.input_calls
	var sims := m.simulate_calls
	var effects := m.effects
	var bystander := other.simulate_calls
	m.pos = Vector3(99, 99, 99) # a wrong current state: the replay must not care

	_check(nt.rollback(from), "rollback returns true")
	_check(m.pos.is_equal_approx(expected_end), "replay ends exactly where the real run ended")
	var all_same := true
	for t in range(from, now + 1):
		all_same = all_same and s.matches_state(t, expected[t])
	_check(all_same, "every replayed tick's saved state matches the original")
	_check(nt.tick == now, "the tick counter is back where it was")
	_check(m.simulate_calls - sims == 20, "simulated once per replayed tick")
	_check(m.input_calls == inputs, "input phase doesn't run during replay; saved inputs are restored")
	_check(m.effects == effects, "cosmetic effects don't replay")
	_check(m.replay_ticks == range(from + 1, now + 1), "is_resimulating is on, and TickDriver.tick reads the replayed tick")
	_check(not nt.is_resimulating(), "is_resimulating is off afterwards")
	_check(m.rolls_repeat, "tick_rng gives the same rolls in a replay")
	_check(other.simulate_calls == bystander, "participants with no rollback state aren't replayed")
	_check(signals == [[from, now]], "after_rollback reports the replayed range")

	# A correction from the authority shifts everything after it.
	_check(s.correct_state(from, {"pos": expected[from]["pos"] + Vector3(0, 0, 10)}), "correct_state accepts a recent tick")
	nt.rollback(from)
	_check(m.pos.is_equal_approx(expected_end + Vector3(0, 0, 10)), "corrected state carries through the replay")
	_check(not s.matches_state(now, expected[now]), "matches_state notices the difference")

	# Normal ticking continues from the replayed state.
	var before: Vector3 = m.pos
	nt.step()
	_check(m.pos.z > before.z and nt.tick == now + 1, "ticking continues normally after a rollback")

	var settled: Vector3 = m.pos
	_check(not nt.rollback(nt.tick + 5), "a future tick: false")
	_check(not nt.rollback(-1), "a negative tick: false")
	_check(not nt.rollback(nt.tick - 500), "a tick that's gone: false")
	_check(m.pos == settled, "...and the state is untouched by those")
	_check(nt.rollback(nt.tick) and m.pos == settled, "rolling back to the latest tick replays nothing and changes nothing")

	nt.after_rollback.disconnect(on_rollback)
	other.free()
	m.free()


func _test_rollback_timing() -> void:
	var m := _mover()
	m.plan = func(_t): return Vector3(1, 0, 0)
	for i in 10:
		nt.step()

	# During a tick's phases: refused. A participant tries it from its simulate.
	var result := [true]
	var tryer := Bystander.new()
	tryer.set_script(_tryer_script())
	tryer.set(&"attempt", func(): result[0] = nt.rollback(nt.tick - 2))
	add_child(tryer)
	nt.register(tryer)
	nt.step()
	_check(not result[0], "rollback during the phases is refused")
	tryer.free()

	# From before_tick: replays up to the last finished tick, then that tick runs normally.
	var seen := []
	var on_before := func(_dt, t):
		seen.append(t)
		seen.append(nt.rollback(t - 5))
		seen.append(nt.tick)
	nt.before_tick.connect(on_before)
	var sims := m.simulate_calls
	nt.step()
	nt.before_tick.disconnect(on_before)
	_check(seen[1] == true and seen[2] == seen[0], "rollback from before_tick works and leaves the tick number alone")
	_check(m.simulate_calls - sims == 5, "replays 4 finished ticks, then runs the current one once")
	m.free()


func _tryer_script() -> GDScript:
	var script := GDScript.new()
	script.source_code = "extends Node\nvar attempt: Callable\nfunc _tick_simulate(_dt, _t):\n\tattempt.call()\n"
	script.reload()
	return script


func _test_custom_state() -> void:
	var c := CustomSaver.new()
	var s := TickStateComponent.new()
	s.name = "State"
	c.name = "Saver"
	c.add_child(s)
	add_child(c)
	nt.register(c)
	for i in 10:
		nt.step()
	var from := nt.tick - 4
	c.bag["count"] = 1000
	_check(nt.rollback(from), "a parent with save_state/load_state counts as predicted, with no lists")
	_check(c.bag["count"] == 10, "custom state restored and replayed")
	_check(s.get_state(from).has("Saver"), "custom state appears in get_state under the node's name")
	nt.unregister(c)
	c.free()

	var bad := Mover.new()
	var bs := TickStateComponent.new()
	bs.custom_state_nodes = [NodePath("../Nope")]
	bad.add_child(bs)
	add_child(bad)
	nt.step()
	_check(bs.get_state(nt.tick).is_empty(), "a missing custom state node warns and is skipped")
	bad.free()


## Lists and dictionaries used to be saved by reference, so every tick shared one object.
func _test_containers() -> void:
	var b := BufferEntity.new()
	b.name = "Buffer"
	var s := TickStateComponent.new()
	s.state_properties = ["buffer", "table"]
	b.add_child(s)
	add_child(b)
	nt.register(b)
	for i in 10:
		nt.step()
	var now := nt.tick
	var from := now - 4
	_check(s.get_state(from)["buffer"].size() == 6, "an Array in the state keeps its contents per tick")
	var returned: Array = s.get_state(from)["buffer"]
	returned.append(999)
	_check(s.get_state(from)["buffer"].size() == 6, "changing what get_state returned doesn't change the history")
	var end_buffer := b.buffer.duplicate()
	var end_table := b.table.duplicate(true)
	b.buffer.append(12345)
	_check(nt.rollback(from), "rollback with Array and Dictionary state")
	_check(b.buffer == end_buffer, "an Array rolls back and replays to the same contents")
	_check(b.table == end_table, "a Dictionary rolls back and replays to the same contents")
	nt.step()
	_check(s.get_state(from + 1)["buffer"].size() == 7, "the live Array growing later doesn't change saved ticks")
	var expected_table: Dictionary = s.get_state(now)["table"]
	expected_table["count"] = -1
	_check(s.matches_state(now, {"buffer": end_buffer}), "matches_state compares Arrays by contents")
	_check(not s.matches_state(now, {"buffer": [1]}), "...and notices a different Array")
	nt.unregister(b)
	b.free()

	var holder := ObjectHolder.new()
	holder.name = "Holder"
	var hs := TickStateComponent.new()
	hs.state_properties = ["thing"]
	holder.add_child(hs)
	add_child(holder)
	nt.step()
	_check(hs.get_state(nt.tick).has("thing"), "an Object in a list warns but doesn't error")
	holder.free()

	var keeper := CustomSaver.new()
	var ks := TickStateComponent.new()
	keeper.add_child(ks)
	add_child(keeper)
	nt.register(keeper)
	for i in 4:
		nt.step()
	var at := nt.tick - 1
	nt.rollback(at)
	keeper.bag["count"] = -50 # load_state kept the Dictionary it was given; that must not be the history's own
	_check(ks.get_state(at)[String(keeper.name)]["count"] != -50, "load_state can keep what it's given without changing the history")
	nt.unregister(keeper)
	keeper.free()


## Parts that arrive after the component is ready, or leave at runtime.
func _test_late_and_removed_nodes() -> void:
	var root := Node.new()
	root.name = "Assembled"
	var s := TickStateComponent.new()
	s.state_properties = ["Late:pos", "Other:pos"]
	root.add_child(s)
	var other := Mover.new()
	other.name = "Other"
	other.pos = Vector3(1, 0, 0)
	root.add_child(other)
	add_child(root)

	nt.step()
	var before_late := nt.tick
	_check(not s.get_state(before_late).has("Late:pos"), "a node that doesn't exist yet: nothing saved, warned, no error")
	_check(s.get_state(before_late).has("Other:pos"), "...the other entries still work")

	var late := Mover.new()
	late.name = "Late"
	late.pos = Vector3(5, 0, 0)
	root.add_child(late)
	nt.step()
	_check(s.get_state(nt.tick).get("Late:pos") == Vector3(5, 0, 0), "added later: picked up on the next tick")

	var with_late := nt.tick
	late.pos = Vector3(7, 0, 0)
	nt.step()
	var after_change := nt.tick
	_check(nt.rollback(with_late) and late.pos == Vector3(5, 0, 0), "a late node rolls back like any other")
	late.pos = Vector3(7, 0, 0)

	# Going back to before it existed leaves it alone: there's nothing saved for it.
	_check(nt.rollback(before_late) and late.pos.is_equal_approx(Vector3(7, 0, 0)), "a tick from before it existed doesn't touch it")
	nt.step()
	_check(s.get_state(nt.tick).has("Late:pos"), "...and it's saved again afterwards")

	late.free()
	nt.step()
	_check(not s.get_state(nt.tick).has("Late:pos"), "a freed node stops being saved, with no error")
	_check(nt.rollback(after_change), "rolling back across a freed node works, with no error")

	# It can come back, and a part of a different type under the same name is fine.
	var again := Mover.new()
	again.name = "Late"
	root.add_child(again)
	nt.step()
	_check(s.get_state(nt.tick).has("Late:pos"), "a replacement under the same name is picked up")
	root.free()

	# Nothing usable at all: not predicted, so a rollback must not re-run its simulation over unrestored state.
	var hollow := Mover.new()
	hollow.name = "Hollow"
	var hs := TickStateComponent.new()
	hs.state_properties = ["no_such_thing"]
	hollow.add_child(hs)
	add_child(hollow)
	nt.register(hollow)
	nt.step()
	nt.step()
	var sims := hollow.simulate_calls
	_check(not nt.rollback(nt.tick - 1) and hollow.simulate_calls == sims, "only unusable entries: not replayed")
	nt.unregister(hollow)
	hollow.free()

	# A property set in the owner's _ready, which runs after this component's, still gets its real encoding.
	var owner_node := ReadySetter.new()
	owner_node.name = "ReadySetter"
	var os := TickStateComponent.new()
	os.state_properties = ["late_value"]
	owner_node.add_child(os)
	add_child(owner_node)
	nt.step()
	_check(owner_node.late_value == Vector3(1.235, 0, 0), "a value set in the owner's _ready is still rounded by its type")
	owner_node.free()


func _test_real_body(along_amount: float, jump_every: int) -> void:
	print("        path: pushing along the wall %.2f, jumping every %d ticks" % [along_amount, jump_every])
	var world := Node3D.new()
	add_child(world)
	world.add_child(_box(Vector3(60, 1, 60), Vector3(0, -0.5, 0)))
	world.add_child(_box(Vector3(1, 3, 40), Vector3(3, 1.5, 0))) # a wall to slide along

	var pawn := _scripted_pawn("Scripted", Vector3(1, 0, 0), 1.0)
	pawn.along_amount = along_amount
	pawn.jump_every = jump_every
	var state: TickStateComponent = pawn.get_node("TickState")
	world.add_child(pawn)

	nt.active = true
	await _frames(20)
	_check(pawn.grounded, "real body: settles on the floor with rounding on")

	# Stand still: rounding must not make the floor contact flicker.
	var flickers := 0
	var idle_start := pawn.position
	for i in 60:
		await get_tree().physics_frame
		if not pawn.grounded:
			flickers += 1
	_check(flickers == 0, "real body: standing still stays grounded for 60 ticks (%d flickers)" % flickers)
	_check(pawn.position.distance_to(idle_start) < 0.002, "real body: standing still doesn't creep")

	pawn.start_tick = nt.tick
	await _frames(300)
	_check(pawn.jump_effects_played >= 3, "real body: the script really jumped (%d jumps)" % pawn.jump_effects_played)
	_check(pawn.wall_ticks.size() > 20, "real body: really pushed into the wall (%d ticks touching it)" % pawn.wall_ticks.size())
	# Rounded positions and the default 1 mm safe margin used to make a walking pawn drop about 6 mm into the floor at times.
	_check(pawn.lowest_grounded_y > -0.0005, "real body: never sinks into the floor while walking (lowest %.4f m)" % pawn.lowest_grounded_y)

	# The engine's private floor flag holds whatever the body is doing NOW, so replays are checked from both situations.
	await _run_until(pawn, true)
	await _check_replays(pawn, state, "while grounded")
	nt.active = true
	await _run_until(pawn, false)
	await _check_replays(pawn, state, "while airborne")
	var now := nt.tick
	var expected: Dictionary = {}
	for t in range(now - 30, now + 1):
		expected[t] = state.get_state(t)

	# A correction: the server says we were 2 m away. The rest of the run should shift with it.
	var from := now - 30
	var original_end: Vector3 = expected[now]["position"]
	state.correct_state(from, {"position": expected[from]["position"] + Vector3(-2, 0, 0)})
	nt.rollback(from)
	var shift := pawn.position.x - original_end.x
	print("        corrected 2 m at tick %d: end position moved %.3f m" % [from, shift])
	_check(shift < -0.5, "real body: a correction carries through the replay")

	world.queue_free()
	await _frames(2)


## Keeps ticking until the pawn is grounded or airborne as asked, then pauses ticking.
func _run_until(pawn: ScriptedPawn, grounded: bool) -> void:
	for i in 200:
		if pawn.grounded == grounded:
			break
		await get_tree().physics_frame
	nt.active = false
	await get_tree().physics_frame


## Replays from every tick in the history and compares each result with what really happened.
func _check_replays(pawn: ScriptedPawn, state: TickStateComponent, situation: String) -> void:
	var now := nt.tick
	var oldest := now - 55
	var expected: Dictionary = {}
	for t in range(oldest, now + 1):
		expected[t] = state.get_state(t)
	var wall_in_window := 0
	for t in range(oldest, now + 1):
		if pawn.wall_ticks.has(t):
			wall_in_window += 1
	var mismatches := 0
	var longest_off := 0
	var worst := 0.0
	var first := ""
	var effects := pawn.jump_effects_played
	for from in range(oldest, now):
		_replayed_from_air = _replayed_from_air or not expected[from]["grounded"]
		_replayed_from_ground = _replayed_from_ground or expected[from]["grounded"]
		state.correct_state(from, expected[from]) # start each replay from the original, not an earlier replay's result
		nt.rollback(from)
		var off_ticks := 0
		for t in range(from, now + 1):
			if (state.get_state(t)["position"] - expected[t]["position"]).length() > 0.0015:
				off_ticks += 1
		longest_off = maxi(longest_off, off_ticks)
		for t in range(from, now + 1):
			if not state.matches_state(t, expected[t]):
				mismatches += 1
				if first == "":
					first = "from %d, tick %d: got %s, expected %s" % [from, t, state.get_state(t), expected[t]]
			worst = maxf(worst, (state.get_state(t)["position"] - expected[t]["position"]).length())
		await get_tree().physics_frame
	print("        %s: %d replays, %d mismatched ticks, worst position error %.4f m, at most %d ticks off in one replay, %d wall ticks" % [situation, now - oldest, mismatches, worst, longest_off, wall_in_window])
	if first != "":
		print("        first mismatch: " + first)
	_check(wall_in_window > 0, "real body %s: the replays covered wall contact (%d ticks)" % [situation, wall_in_window])
	# Not zero on every path: contact with a wall or floor still occasionally comes out a little differently, so this is
	# a bound. A broken replay is far outside it (a rotating body gave 19.5 cm, lasting 42 ticks).
	_check(worst <= 0.01, "real body %s: replaying from any tick stays within 1 cm of the original run" % situation)
	_check(longest_off <= 3, "real body %s: any difference is gone within a few ticks" % situation)
	_check(pawn.jump_effects_played == effects, "real body %s: jump effects don't replay" % situation)


## Claude 2026-11-04: a FOLLOW_SERVER entity stands where the server says during a replay, estimates past that on its velocity,
## and runs nothing of its own. The watcher simulates during the replay, so it shows where the entity stood on each tick.
func _test_follow_server() -> void:
	var follower := MovingFollower.new()
	var state := _follow_server_state(follower)
	follower.position = Vector3(99, 0, 0)
	var watcher := Watcher.new()
	watcher.target = follower
	var watcher_state := TickStateComponent.new()
	watcher_state.state_properties = ["count"]
	watcher.add_child(watcher_state)
	add_child(watcher)
	nt.register(watcher)
	_check(state._states.size() == 2 and state._position_index == 0 and state._velocity_index == 1, "follow server with nothing listed uses position, and velocity if the parent has one")
	_check(state.get_schema().is_empty(), "follow server: that default isn't added to the list the handshake compares")
	state.extrapolation_cap_seconds = 0.05 # 3 ticks

	var first := nt.tick + 1
	for i in 12:
		nt.step()
	_check(not state.has_state(first + 3), "follow server: it keeps no history of its own")

	_check(nt.rollback(first + 1), "follow server: the rollback happens")
	_check(_saw(watcher, first + 3, Vector3(99, 0, 0)), "follow server: with no server data, it stays where it is")

	# 60 m/s is 1 m per tick at 60 ticks/s, so the estimates are easy to read.
	state.receive_authoritative_state(first + 2, {"position": Vector3(1, 0, 0), "velocity": Vector3(60, 60, 0), "not_listed": true})
	state.receive_authoritative_state(first + 3, {"position": Vector3(5, 0, 0), "velocity": Vector3(60, 60, 0)})
	follower.simulate_calls = 0
	nt.rollback(first + 1)
	_check(_saw(watcher, first + 2, Vector3(1, 0, 0)) and _saw(watcher, first + 3, Vector3(5, 0, 0)), "follow server: on ticks the server sent, it stands exactly there")
	_check(_saw(watcher, first + 4, Vector3(6, 0, 0)) and _saw(watcher, first + 6, Vector3(8, 0, 0)), "follow server: past the newest server data, it moves on its velocity, ignoring up and down")
	_check(_saw(watcher, first + 7, Vector3(8, 0, 0)) and _saw(watcher, first + 11, Vector3(8, 0, 0)), "follow server: at the cap, it holds")
	_check(follower.position == Vector3(99, 0, 0), "follow server: afterwards it has exactly what it had before")
	_check(follower.simulate_calls == 0, "follow server: its own simulation doesn't run")
	_check(follower.loaded_calls == 0, "follow server: _on_state_loaded doesn't run")

	nt.rollback(first + 5)
	_check(_saw(watcher, first + 6, Vector3(8, 0, 0)), "follow server: a replay starting past the newest server data estimates from it straight away")

	state.clear_authoritative_state()
	state.receive_authoritative_state(first + 2, {"position": Vector3(1, 0, 0), "velocity": Vector3(60, 0, 0)})
	state.receive_authoritative_state(first + 4, {"position": Vector3(20, 0, 0), "velocity": Vector3(60, 0, 0)})
	nt.rollback(first + 1)
	_check(_saw(watcher, first + 3, Vector3(2, 0, 0)) and _saw(watcher, first + 4, Vector3(20, 0, 0)), "follow server: between server ticks it estimates, then snaps to the next one")

	state.clear_authoritative_state()
	nt.rollback(first + 1)
	_check(_saw(watcher, first + 3, Vector3(99, 0, 0)), "follow server: clear_authoritative_state forgets what it was told")

	state.extrapolate_vertical = true
	state.receive_authoritative_state(first + 2, {"position": Vector3(1, 0, 0), "velocity": Vector3(60, 60, 0)})
	nt.rollback(first + 2)
	_check(_saw(watcher, first + 3, Vector3(2, 1, 0)), "follow server: extrapolate_vertical also moves it up and down")
	state.extrapolate_vertical = false

	state.extrapolation_cap_seconds = 0.0
	nt.rollback(first + 2)
	_check(_saw(watcher, first + 3, Vector3(1, 0, 0)), "follow server: a cap of 0 just holds at the newest server data")
	state.extrapolation_cap_seconds = 0.05

	state.clear_authoritative_state()
	state.receive_authoritative_state(first + 2 + state.history_size, {"position": Vector3(1, 0, 0)})
	state.receive_authoritative_state(first + 2, {"position": Vector3(50, 0, 0)})
	nt.rollback(first + 1)
	_check(_saw(watcher, first + 2, Vector3(99, 0, 0)), "follow server: a late packet doesn't replace newer data in its slot")

	var door := Follower.new()
	var door_state := _follow_server_state(door)
	door.position = Vector3(7, 0, 0)
	_check(door_state._states.size() == 1, "follow server: with no velocity on the parent, it only uses position")
	door_state.receive_authoritative_state(first + 2, {"position": Vector3(3, 0, 0)})
	watcher.target = door
	nt.rollback(first + 2)
	_check(_saw(watcher, first + 5, Vector3(3, 0, 0)), "follow server: with no velocity, it holds at the newest server data")
	_check(door.position == Vector3(7, 0, 0), "follow server: ...and gets its own position back afterwards")

	var sprite := MovingFollower2D.new()
	var sprite_state := _follow_server_state(sprite)
	sprite.position = Vector2(4, 4)
	sprite_state.receive_authoritative_state(first + 2, {"position": Vector2(1, 1), "velocity": Vector2(60, 60)})
	watcher.target = sprite
	nt.unregister(watcher_state) # to the back of the order, so it looks after the newer entity has moved this tick
	nt.register(watcher_state)
	nt.rollback(first + 2)
	_check(_saw(watcher, first + 3, Vector2(2, 2)), "follow server: Vector2 moves on both axes")

	var motored := Node3D.new()
	var motor := MotorPart.new()
	motor.name = "Motor"
	motored.add_child(motor)
	var motored_state := TickStateComponent.new()
	motored_state.rollback_mode = TickStateComponent.RollbackMode.FOLLOW_SERVER
	motored_state.follows_during_rollback = true
	motored_state.state_properties = ["global_position", "Motor:velocity"]
	motored.add_child(motored_state)
	add_child(motored)
	motored_state.receive_authoritative_state(first + 2, {"global_position": Vector3(1, 0, 0), "Motor:velocity": Vector3(60, 0, 0)})
	watcher.target = motored
	nt.unregister(watcher_state)
	nt.register(watcher_state)
	nt.rollback(first + 2)
	_check(_saw(watcher, first + 3, Vector3(2, 0, 0)), "follow server: a velocity on a part below the parent, and global_position, still estimate")

	# The distance cutoff: the watcher has no position, so give it one by replaying a moved entity next to the follower.
	var near_state := _follow_server_state(MovingFollower.new())
	var far_state := _follow_server_state(MovingFollower.new())
	var near: Node3D = near_state.get_parent()
	var far: Node3D = far_state.get_parent()
	near.position = Vector3(5, 0, 0)
	far.position = Vector3(500, 0, 0)
	near_state.receive_authoritative_state(first + 2, {"position": Vector3(6, 0, 0)})
	far_state.receive_authoritative_state(first + 2, {"position": Vector3(600, 0, 0)})
	var centre := Node3D.new()
	var centre_state := TickStateComponent.new()
	centre_state.state_properties = ["position"]
	centre.add_child(centre_state)
	add_child(centre)
	var from := nt.tick + 1
	nt.step()
	nt.step()
	near_state.receive_authoritative_state(from, {"position": Vector3(7, 0, 0)})
	far_state.receive_authoritative_state(from, {"position": Vector3(700, 0, 0)})
	_check(near_state.is_near_any([Vector3.ZERO]) and not far_state.is_near_any([Vector3.ZERO]), "distance cutoff: near is in, far is out")
	far_state.follow_server_radius = 0.0
	_check(far_state.is_near_any([Vector3.ZERO]), "distance cutoff: a radius of 0 means no limit")
	far_state.follow_server_radius = 10.0
	var far_loads_before: Vector3 = far.position
	nt.rollback(from)
	_check(far.position == far_loads_before and far_state._live_values.is_empty(), "distance cutoff: a far entity doesn't join the rollback at all")

	# By default a following entity stays where it's drawn during a rollback, the standard behaviour.
	var stays_state := TickStateComponent.new()
	stays_state.rollback_mode = TickStateComponent.RollbackMode.FOLLOW_SERVER
	var stays := MovingFollower.new()
	stays.position = Vector3(1, 0, 0)
	stays.add_child(stays_state)
	add_child(stays)
	stays_state.receive_authoritative_state(from, {"position": Vector3(3, 0, 0)})
	stays_state._live_values = []
	nt.rollback(from)
	_check(not stays_state.wants_to_join_rollback([]) and stays_state._live_values.is_empty(), "follow server: by default it doesn't join a rollback")
	_check(stays.position == Vector3(1, 0, 0), "follow server: and stays where it's drawn")
	nt.unregister(stays_state)
	stays.free()

	# With nothing resimulated, a rollback has nothing to do.
	for node: Node in [watcher, centre]:
		nt.unregister(node.get_child(-1))
	near_state.receive_authoritative_state(nt.tick, {"position": Vector3(8, 0, 0)})
	var near_before: Vector3 = near.position
	_check(not nt.rollback(nt.tick), "a rollback with only following entities does nothing and returns false")
	_check(near.position == near_before, "...and doesn't move them")

	for node: Node in [follower, door, sprite, motored, watcher, near, far, centre]:
		nt.unregister(node)
		node.free()

	# Load hooks run with the replay flag on, once everything is loaded.
	var first_hook := LoadHookEntity.new()
	var second_hook := LoadHookEntity.new()
	first_hook.other = second_hook
	for hook in [first_hook, second_hook]:
		var hook_state := TickStateComponent.new()
		hook_state.state_properties = ["value"]
		hook.add_child(hook_state)
		add_child(hook)
	second_hook.value = 42
	var hook_tick := nt.tick + 1
	nt.step()
	second_hook.value = 1
	nt.step()
	nt.rollback(hook_tick)
	_check(first_hook.flag_during_load, "load hooks run with is_resimulating on")
	_check(first_hook.other_value_during_load == 42, "load hooks run after every entity is loaded, so they see the others put back")
	first_hook.free()
	second_hook.free()


func _follow_server_state(entity: Node) -> TickStateComponent:
	var state := TickStateComponent.new()
	state.rollback_mode = TickStateComponent.RollbackMode.FOLLOW_SERVER
	state.follows_during_rollback = true
	entity.add_child(state)
	add_child(entity)
	return state


## Where the watcher saw its target on a tick, within 1 mm, because server values are rounded to that.
func _saw(watcher: Watcher, tick: int, where: Variant) -> bool:
	return (watcher.seen[tick] - where).length() <= 0.001


## Pawns colliding with each other during a replay.
func _test_two_bodies() -> void:
	await _test_sync_reaches_collision_world()
	await _two_bodies_both_predicted()
	await _two_bodies_only_a_predicted()


## A moved body normally reaches the collision world only at the next physics step. _sync_collision must beat that.
func _test_sync_reaches_collision_world() -> void:
	var world := Node3D.new()
	add_child(world)
	var pawn := _scripted_pawn("Moved", Vector3.ZERO, 1.0)
	world.add_child(pawn)
	await _frames(3)
	var query := PhysicsPointQueryParameters3D.new()
	query.position = Vector3(10, 0.9, 0)
	var space := pawn.get_world_3d().direct_space_state
	pawn.position = Vector3(10, 0, 0)
	var state: TickStateComponent = pawn.get_node("TickState")
	var started := Time.get_ticks_usec()
	for i in 100:
		state._sync_collision()
	print("        _sync_collision costs about %.1f microseconds per call" % ((Time.get_ticks_usec() - started) / 100.0))
	_check(space.intersect_point(query).size() == 1, "_sync_collision: the collision world sees the moved body straight away")
	_check(PhysicsServer3D.body_get_mode(pawn.get_rid()) == PhysicsServer3D.BODY_MODE_KINEMATIC, "_sync_collision: the body's mode is restored")
	world.queue_free()
	await _frames(2)


## Claude 2026-11-04: both pawns replay together, so the replay must reproduce the run.
func _two_bodies_both_predicted() -> void:
	var setup: Dictionary = await _two_pawns_pushing()
	var a: ScriptedPawn = setup["a"]
	var b: ScriptedPawn = setup["b"]
	var state_a: TickStateComponent = a.get_node("TickState")
	var state_b: TickStateComponent = b.get_node("TickState")
	var now := nt.tick
	var oldest := now - 40
	var expected_a := _saved_states(state_a, oldest, now)
	var expected_b := _saved_states(state_b, oldest, now)
	_check(_bumps_between(a, oldest, now) > 0, "two bodies, both predicted: they really pushed against each other")
	var worst: Dictionary = await _replay_every_tick(state_a, expected_a, state_b, expected_b, oldest, now)
	print("        both predicted, " + _describe_worst(worst))
	_check(worst[40] <= 0.01, "two bodies, both predicted: a replay reproduces the run, within 1 cm")
	setup["world"].queue_free()
	await _frames(2)


## Claude 2026-11-04: the normal client situation, where A replays and B doesn't, with B following the server.
func _two_bodies_only_a_predicted() -> void:
	var setup: Dictionary = await _two_pawns_pushing()
	var a: ScriptedPawn = setup["a"]
	var b: ScriptedPawn = setup["b"]
	var state_a: TickStateComponent = a.get_node("TickState")
	var state_b: TickStateComponent = b.get_node("TickState")
	var now := nt.tick
	var expected_a := _saved_states(state_a, now - 40, now)
	var expected_b := _saved_states(state_b, now - 40, now)
	state_b.rollback_mode = TickStateComponent.RollbackMode.FOLLOW_SERVER
	state_b.follows_during_rollback = true

	state_b.receive_authoritative_state(now - 40, expected_b[now - 40])
	state_a.correct_state(now - 40, expected_a[now - 40])
	var position_before := b.position
	var velocity_before := b.velocity
	var model_before := b._curr_xform
	b.simulate_calls = 0
	nt.rollback(now - 40)
	_check(b.position == position_before and b.velocity == velocity_before, "follow server, real body: position and velocity are back after the replay")
	_check(b.simulate_calls == 0, "follow server, real body: move_and_slide doesn't run for it")
	_check(b._curr_xform == model_before, "follow server, real body: its visible model isn't disturbed")
	_check(PhysicsServer3D.body_get_mode(b.get_rid()) == PhysicsServer3D.BODY_MODE_KINEMATIC, "follow server, real body: its mode is restored")
	b.position = Vector3(20, 0, 0)
	state_b.follow_server_radius = 0.0 # moved far away on purpose; the cutoff has its own test
	nt.rollback(now - 40)
	var query := PhysicsPointQueryParameters3D.new()
	query.position = Vector3(20, 0.9, 0)
	_check(b.get_world_3d().direct_space_state.intersect_point(query).size() == 1, "follow server, real body: the collision world has it back at its live position")
	setup["world"].queue_free()
	await _frames(2)

	var results: Dictionary = await _measure_estimates([[0.6, 47], [0.25, 47]], [0, 20], [0.2], 20)
	_check(results["cap 0.2"][12][0] < results["drawn"][12][0], "follow server: estimating from server data beats holding the pawn where it's drawn, on replays of 7-12 ticks")


## Claude 2026-11-04: compares where to put a pawn that isn't replayed, using the real code path. B changes direction at
## random, and both pawns seek each other so they stay in contact. As on a client at this ping, the newest server data is
## the replay's first tick, and B is drawn 6 ticks (100 ms) older than that. Replays start from the true A, so the error is
## how far each ended from what really happened. Stands in for a network: exact inputs, constant delay, no loss or jitter.
## Returns {name: {longest replay in the group: [average m, worst m]}}, and prints them.
func _measure_estimates(paths: Array, extra_ticks: Array, caps: Array, window: int) -> Dictionary:
	var names: Array[String] = ["drawn"]
	for cap in caps:
		names.append("cap %s" % str(cap))
	var totals := {}
	var usec := {}
	var replayed := {}
	for path in paths:
		for extra: int in extra_ticks:
			var setup: Dictionary = await _two_pawns_pushing(path[0], path[1], true, extra)
			var a: ScriptedPawn = setup["a"]
			var b: ScriptedPawn = setup["b"]
			var state_a: TickStateComponent = a.get_node("TickState")
			var state_b: TickStateComponent = b.get_node("TickState")
			var now := nt.tick
			var oldest := now - window
			var expected_a := _saved_states(state_a, oldest, now)
			var expected_b := _saved_states(state_b, oldest - 6, now)
			state_b.rollback_mode = TickStateComponent.RollbackMode.FOLLOW_SERVER
			state_b.follows_during_rollback = true
			for option_name: String in names:
				if option_name == "drawn":
					nt.unregister(state_b)
				else:
					nt.register(state_b)
					state_b.extrapolation_cap_seconds = float(option_name.trim_prefix("cap "))
				for from in range(oldest, now):
					if option_name == "drawn":
						b.position = expected_b[from - 6]["position"]
						state_b._sync_collision()
					else:
						state_b.clear_authoritative_state()
						state_b.receive_authoritative_state(from, expected_b[from])
					state_a.correct_state(from, expected_a[from])
					var started := Time.get_ticks_usec()
					nt.rollback(from)
					usec[option_name] = usec.get(option_name, 0) + Time.get_ticks_usec() - started
					replayed[option_name] = replayed.get(option_name, 0) + now - from
					var error: float = (state_a.get_state(now)["position"] - expected_a[now]["position"]).length()
					var length := now - from
					var group := 6 if length <= 6 else (12 if length <= 12 else (20 if length <= 20 else 40))
					var key := "%s %d" % [option_name, group]
					if not totals.has(key):
						totals[key] = [0.0, 0, 0.0]
					totals[key][0] += error
					totals[key][1] += 1
					totals[key][2] = maxf(totals[key][2], error)
					await get_tree().physics_frame
			setup["world"].queue_free()
			await _frames(2)
	var results := {}
	for option_name: String in names:
		results[option_name] = {}
		var line := "        %-9s" % option_name
		var shortest := 1
		for group in [6, 12, 20, 40]:
			var key := "%s %d" % [option_name, group]
			if totals.has(key):
				var v: Array = totals[key]
				results[option_name][group] = [v[0] / v[1], v[2]]
				line += " | %d-%d ticks: %.1f (%.1f) cm" % [shortest, group, 100.0 * v[0] / v[1], 100.0 * v[2]]
			shortest = group + 1
		print(line + " | %.1f us per replayed tick" % (float(usec[option_name]) / replayed[option_name]))
	return results


## A world with two pawns, run until the last 40 ticks include real contact between them, plus extra_ticks. Ticking is off
## when it returns. seeking: they walk toward each other, and B changes direction at random.
func _two_pawns_pushing(along_amount: float = 0.6, jump_every: int = 47, seeking: bool = false, extra_ticks: int = 0) -> Dictionary:
	var world := Node3D.new()
	add_child(world)
	world.add_child(_box(Vector3(60, 1, 60), Vector3(0, -0.5, 0)))
	var a := _scripted_pawn("A", Vector3(-1.5, 0, 0), 1.0)
	var b := _scripted_pawn("B", Vector3(1.5, 0, 0), -1.0)
	a.along_amount = along_amount
	b.along_amount = along_amount
	a.jump_every = jump_every
	b.jump_every = jump_every + 7 if seeking else jump_every
	if seeking:
		a.seek = b
		b.seek = a
		b.change_every = 10
	world.add_child(a)
	world.add_child(b)
	nt.active = true
	await _frames(10)
	a.start_tick = nt.tick
	b.start_tick = nt.tick
	await _frames(120)
	for i in 400:
		if _bumps_between(a, nt.tick - 40, nt.tick) >= 8:
			break
		await get_tree().physics_frame
	await _frames(extra_ticks)
	nt.active = false
	await get_tree().physics_frame
	return {"world": world, "a": a, "b": b}


func _bumps_between(pawn: ScriptedPawn, from: int, to: int) -> int:
	var bumps := 0
	for t in range(from, to + 1):
		if pawn.body_bump_ticks.has(t):
			bumps += 1
	return bumps


func _saved_states(state: TickStateComponent, from: int, to: int) -> Dictionary:
	var out: Dictionary = {}
	for t in range(from, to + 1):
		out[t] = state.get_state(t)
	return out


## Replays from every tick in the window, each starting from the true state. Returns the worst position error seen, as
## {replay length in ticks: metres}, each covering all replays up to that length. state_b may be null: not checked.
func _replay_every_tick(state_a: TickStateComponent, expected_a: Dictionary, state_b: TickStateComponent, expected_b: Dictionary, oldest: int, now: int) -> Dictionary:
	var worst := {6: 0.0, 12: 0.0, 20: 0.0, 40: 0.0}
	for from in range(oldest, now):
		state_a.correct_state(from, expected_a[from])
		if state_b:
			state_b.correct_state(from, expected_b[from])
		nt.rollback(from)
		var error := 0.0
		for t in range(from, now + 1):
			error = maxf(error, (state_a.get_state(t)["position"] - expected_a[t]["position"]).length())
			if state_b:
				error = maxf(error, (state_b.get_state(t)["position"] - expected_b[t]["position"]).length())
		for length in worst:
			if now - from <= length:
				worst[length] = maxf(worst[length], error)
		await get_tree().physics_frame
	return worst


func _describe_worst(worst: Dictionary) -> String:
	return "worst error by replay length: 6 ticks %.3f m, 12 ticks %.3f m, 20 ticks %.3f m, 40 ticks %.3f m" % [worst[6], worst[12], worst[20], worst[40]]


## Claude 2026-11-04: time dilation and catching up after a hitch make some frames run two ticks, or none, while the
## server runs exactly one per frame. The same inputs must give the same result however the ticks fall across frames.
func _test_uneven_frames() -> void:
	var one_pawn: Dictionary = await _uneven_frames_run(false, 0, 0)
	var two_pawns: Dictionary = await _uneven_frames_run(true, 0, 0)
	var two_pawns_again: Dictionary = await _uneven_frames_run(true, 0, 0)
	_check(two_pawns["bumps"] >= 20, "uneven frames: the pawns really pushed against each other (%d ticks)" % two_pawns["bumps"])
	_compare_paths("the same frames twice, two pawns", two_pawns, two_pawns_again)
	_compare_paths("one pawn, two ticks every 10 frames", one_pawn, await _uneven_frames_run(false, 10, 0))
	_compare_paths("two pawns, two ticks every 50 frames", two_pawns, await _uneven_frames_run(true, 50, 0))
	_compare_paths("two pawns, two ticks every 10 frames", two_pawns, await _uneven_frames_run(true, 10, 0))
	_compare_paths("two pawns, no tick every 10 frames", two_pawns, await _uneven_frames_run(true, 0, 10))


## Runs one or two pawns for 360 ticks. Every extra_every frames runs two ticks, and every skip_every frames runs none.
## Returns {"paths": {ticks since start: [position of A, position of B]}, "bumps": ticks of contact}.
func _uneven_frames_run(with_b: bool, extra_every: int, skip_every: int) -> Dictionary:
	var world := Node3D.new()
	add_child(world)
	world.add_child(_box(Vector3(60, 1, 60), Vector3(0, -0.5, 0)))
	var a := _scripted_pawn("A", Vector3(-1.5, 0, 0), 1.0)
	var b := _scripted_pawn("B", Vector3(1.5, 0, 0), -1.0) if with_b else null
	world.add_child(a)
	if b:
		world.add_child(b)
	var dt := nt.get_tick_dt()
	for i in 10: # settle on the floor, one tick per frame
		await get_tree().physics_frame
		nt.advance(dt)
	var start := nt.tick
	a.start_tick = start
	if b:
		b.start_tick = start
	var state_a: TickStateComponent = a.get_node("TickState")
	var state_b: TickStateComponent = b.get_node("TickState") if b else null
	var paths: Dictionary = {}
	var frame := 0
	while nt.tick < start + 360:
		await get_tree().physics_frame
		frame += 1
		var before := nt.tick
		if extra_every > 0 and frame % extra_every == 0:
			nt.advance(dt * 2.0)
		elif skip_every <= 0 or frame % skip_every != 0:
			nt.advance(dt)
		for t in range(before + 1, nt.tick + 1):
			var position_b: Vector3 = state_b.get_state(t)["position"] if state_b else Vector3.ZERO
			paths[t - start] = [state_a.get_state(t)["position"], position_b]
	var bumps := _bumps_between(a, start, nt.tick)
	world.queue_free()
	await _frames(2)
	return {"paths": paths, "bumps": bumps}


func _compare_paths(label: String, reference: Dictionary, other: Dictionary) -> void:
	var worst := 0.0
	var first_off := -1
	for i in reference["paths"]:
		if not other["paths"].has(i):
			continue
		var error := 0.0
		for pawn in 2:
			var one: Vector3 = reference["paths"][i][pawn]
			var two: Vector3 = other["paths"][i][pawn]
			error = maxf(error, one.distance_to(two))
		worst = maxf(worst, error)
		if first_off < 0 and error > 0.0015:
			first_off = i
	print("        %s: worst difference %.3f m, first off at tick %d" % [label, worst, first_off])
	_check(worst <= 0.01, "uneven frames, %s: same result as one tick per frame, within 1 cm" % label)


func _scripted_pawn(pawn_name: String, at: Vector3, wall_sign: float) -> ScriptedPawn:
	var pawn := ScriptedPawn.new()
	pawn.name = pawn_name
	pawn.position = at
	pawn.wall_x_sign = wall_sign
	pawn.brain = TickSamplePawn.Brain.IDLE
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	shape.shape = capsule
	shape.position = Vector3(0, 0.9, 0)
	pawn.add_child(shape)
	var state := TickStateComponent.new()
	state.name = "TickState"
	state.input_properties = ["move_dir", "wants_sprint", "wants_jump"]
	state.state_properties = ["position", "velocity", "yaw @angle_u16", "grounded"]
	pawn.add_child(state)
	return pawn


func _mover() -> Mover:
	var m := Mover.new()
	m.name = "Mover"
	var s := TickStateComponent.new()
	s.input_properties = ["want"]
	s.state_properties = ["pos"]
	m.add_child(s)
	add_child(m)
	nt.register(m)
	return m


func _box(size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	return body


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
