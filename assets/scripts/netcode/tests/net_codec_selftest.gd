## Written by Claude (claude-opus-5-5), 2026-11-05: does C++ packet encoding (NetCodec) match NetPackets.gd exactly, and how
## much faster is it? Part one fails the test on any difference in bytes or values. That matters because machines using either one
## have to play together. Part two prints timings on a snapshot of 100 test pawns, including GDScript written for speed, so C++ is
## compared with the best GDScript can do and not only with NetPackets.
##
## Run: Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/netcode/tests/net_codec_selftest.tscn"
extends Node

const PAWNS := 100
const ROUNDS_PER_TIMING := 30
const TIMINGS := 15 # the middle one is reported, so another program using the computer for a moment doesn't count

const KIND_VECTOR3_MM := 1
const KIND_ANGLE_U16 := 2
const KIND_BOOL := 3
const KIND_INT := 4
const MM_VECTOR := Vector3(StateEncoding.MM, StateEncoding.MM, StateEncoding.MM)
const INT24_LIMIT := NetPackets.INT24_LIMIT

var _rng := RandomNumberGenerator.new()
var _codec := NetCodec.new()
var _failed := 0
var _passed := 0

# The test world: the test pawn's real properties, each pawn different.
var _ids: Array[int] = []
var _states: Array = []
var _syncs: Array = []
var _empty: Array = []
var _state_encodings: Array = [&"vector3_mm", &"vector3_mm", &"angle_u16", &"raw"]
var _sync_encodings: Array = [&"raw"]
var _input_encodings: Array = [&"vector3_mm", &"raw", &"raw", &"raw", &"vector3_mm", &"float"]
var _state_kinds := PackedByteArray([KIND_VECTOR3_MM, KIND_VECTOR3_MM, KIND_ANGLE_U16, KIND_BOOL])
var _sync_kinds := PackedByteArray([KIND_INT])
var _world_bytes: PackedByteArray
var _entries: Array = []


func _ready() -> void:
	_rng.seed = 20261105
	await get_tree().process_frame
	_make_world()
	_check_random_lists(20000)
	_check_cut_short_packets(300)
	_check_garbage(3000)
	_check_oversized_list()
	_check_world()
	print("")
	if _failed == 0:
		_print_timings()
	print("")
	print("%d checks passed, %d failed" % [_passed, _failed])
	print("--- ALL PASSED ---" if _failed == 0 else "--- FAILED ---")
	get_tree().quit(0 if _failed == 0 else 1)


func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		if _failed <= 30:
			print("FAIL ", label)


# --- Part one: the same bytes and values -----------------------------------------------------------

func _random_float() -> float:
	match _rng.randi_range(0, 10):
		0:
			return _rng.randf_range(-20000.0, 20000.0)
		1:
			return _rng.randf_range(-10.0, 10.0)
		2:
			return (_rng.randi_range(-100000, 100000) + 0.5) * StateEncoding.MM # exactly half way between two steps
		3:
			return (_rng.randi_range(-100000, 100000) + 0.5) * StateEncoding.CM
		4:
			return PI + _rng.randf_range(-0.001, 0.001) # the top of an angle's range, where it wraps
		5:
			return -PI + _rng.randf_range(-0.001, 0.001)
		6:
			return _rng.randf_range(-50.0, 50.0) * TAU
		7:
			return (_rng.randi_range(-40000, 40000) + 0.5) * StateEncoding.U16_STEP
		8:
			return (_rng.randi_range(-150, 150) + 0.5) * StateEncoding.BYTE_STEP
		9:
			return _rng.randf_range(-0.0001, 0.0001)
	var odd: Array[float] = [INF, -INF, NAN, -0.0, 0.0, 1e30, -1e30, 8388.607, -8388.607, 8388.608, -8388.608, 83886.07, TAU, -TAU, PI, -PI]
	return odd[_rng.randi_range(0, odd.size() - 1)]


func _random_vector3() -> Vector3:
	return Vector3(_random_float(), _random_float(), _random_float())


func _random_value() -> Variant:
	match _rng.randi_range(0, 19):
		0, 1, 2, 3:
			return _random_vector3()
		4:
			return Vector3(_rng.randf_range(-100, 100), _rng.randf_range(-100, 100), _rng.randf_range(-100, 100)).snapped(MM_VECTOR)
		5, 6:
			return Vector2(_random_float(), _random_float())
		7, 8, 9, 10:
			return _random_float()
		11:
			return _rng.randi_range(0, 1) == 0
		12:
			# Claude 2026-11-07: the edges of the new 1- and 2-byte sizes added (127/128, -128/-129, 32767/32768, -32768/-32769).
			var ints: Array[int] = [0, 1, -1, 127, 128, -128, -129, 32767, 32768, -32768, -32769, 2147483647, -2147483648, 2147483648,
					-2147483649, 9223372036854775807, -9223372036854775807 - 1, _rng.randi()]
			return ints[_rng.randi_range(0, ints.size() - 1)]
		13:
			return null
		14:
			return TickStateComponent.MISSING
		15:
			var others: Array = ["text", &"a_name", "__tick_state_missing__", Vector3i(1, -2, 3), Color(0.1, 0.2, 0.3, 0.4), [1, 2.5, "x", Vector3.ONE], {"a": 1, 2: [3]}, PackedByteArray([1, 2, 3]), PackedVector3Array([Vector3.UP]), "", [], {}]
			return others[_rng.randi_range(0, others.size() - 1)]
		16:
			return RefCounted.new() # objects never go over the wire
		17:
			return Transform3D.IDENTITY.translated(_random_vector3())
		18:
			return StringName("some_name_%d" % _rng.randi_range(0, 3))
	return _rng.randi_range(-3000000, 3000000)


func _random_encoding() -> StringName:
	var names: Array[StringName] = [StateEncoding.AUTO, StateEncoding.VECTOR3_MM, StateEncoding.VECTOR3_CM, StateEncoding.VECTOR2_MM, StateEncoding.ANGLE_U16, StateEncoding.ANGLE_BYTE, StateEncoding.FLOAT, StateEncoding.RAW, &"no_such_encoding"]
	return names[_rng.randi_range(0, names.size() - 1)]


func _random_list() -> Array:
	var values: Array = []
	var encodings: Array = []
	for i in _rng.randi_range(0, 12):
		values.append(_random_value())
		if _rng.randf() < 0.9: # sometimes fewer encodings than values, which means auto
			encodings.append(_random_encoding())
	return [values, encodings]


## Exactly equal: same type, same bits. A plain == would say NaN differs from itself, and 0.0 equals -0.0.
func _same(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and var_to_bytes(a) == var_to_bytes(b)


func _same_lists(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == null and b == null
	if a.size() != b.size():
		return false
	for i in a.size():
		if not _same(a[i], b[i]) or is_same(a[i], TickStateComponent.MISSING) != is_same(b[i], TickStateComponent.MISSING):
			return false
	return true


func _check_random_lists(count: int) -> void:
	var bad_bytes := 0
	var bad_values := 0
	var bad_position := 0
	for n in count:
		var first := _random_list()
		var second := _random_list()
		var buffer := NetPackets.new_buffer()
		NetPackets.write_list(buffer, first[0], first[1])
		NetPackets.write_list(buffer, second[0], second[1])
		buffer.put_u32(0xABCD1234)
		var expected := buffer.data_array

		_codec.begin_write()
		_codec.write_list(first[0], first[1])
		_codec.write_list(second[0], second[1])
		_codec.write_u32(0xABCD1234)
		if _codec.get_written() != expected:
			bad_bytes += 1

		var reader := NetPackets.reader(expected)
		_codec.begin_read(expected)
		for i in 2:
			if not _same_lists(NetPackets.read_list(reader), _codec.read_list()):
				bad_values += 1
		if _codec.read_u32() != 0xABCD1234 or reader.get_u32() != 0xABCD1234:
			bad_position += 1
	_check(bad_bytes == 0, "random lists: %d of %d gave different bytes" % [bad_bytes, count])
	_check(bad_values == 0, "random lists: %d read back different values" % bad_values)
	_check(bad_position == 0, "random lists: %d ended at a different place" % bad_position)
	print("%d random lists: bytes and values compared" % count)


func _check_cut_short_packets(count: int) -> void:
	var differences := 0
	var cuts := 0
	for n in count:
		var list := _random_list()
		var buffer := NetPackets.new_buffer()
		NetPackets.write_list(buffer, list[0], list[1])
		var whole := buffer.data_array
		for cut in whole.size():
			var part := whole.slice(0, cut)
			_codec.begin_read(part)
			if not _same_lists(NetPackets.read_list(NetPackets.reader(part)), _codec.read_list()):
				differences += 1
			cuts += 1
	_check(differences == 0, "cut short packets: %d of %d read differently" % [differences, cuts])
	print("%d cut short packets: same answer from both" % cuts)


## Random bytes, mostly with believable tags. Godot prints errors for the ones that pretend to hold a Variant; that's fine.
func _check_garbage(count: int) -> void:
	var differences := 0
	for n in count:
		var bytes := PackedByteArray()
		bytes.resize(_rng.randi_range(0, 40))
		for i in bytes.size():
			bytes[i] = _rng.randi_range(0, 11) if _rng.randf() < 0.5 else _rng.randi_range(0, 255)
		if bytes.size() > 0:
			bytes[0] = _rng.randi_range(0, 6)
		_codec.begin_read(bytes)
		if not _same_lists(NetPackets.read_list(NetPackets.reader(bytes)), _codec.read_list()):
			differences += 1
	_check(differences == 0, "garbage: %d of %d read differently" % [differences, count])
	print("%d garbage packets: same answer from both" % count)
	# Purely random bytes almost never claim a length that fits, so these aim straight at the branch holding a Godot value.
	var aimed_differences := 0
	for n in 500:
		var payload := PackedByteArray()
		payload.resize(_rng.randi_range(0, 24))
		for i in payload.size():
			payload[i] = _rng.randi_range(0, 255) if _rng.randf() < 0.5 else _rng.randi_range(0, 40)
		var buffer := StreamPeerBuffer.new()
		buffer.put_u8(2)
		buffer.put_u8(NetPackets.Tag.OTHER)
		var lengths: Array[int] = [payload.size(), payload.size(), payload.size() + 1, -1, 2147483647]
		buffer.put_32(lengths[_rng.randi_range(0, lengths.size() - 1)])
		buffer.put_data(payload)
		buffer.put_u8(NetPackets.Tag.BOOL_TRUE)
		var bytes := buffer.data_array
		_codec.begin_read(bytes)
		if not _same_lists(NetPackets.read_list(NetPackets.reader(bytes)), _codec.read_list()):
			aimed_differences += 1
	_check(aimed_differences == 0, "aimed garbage: %d of 500 read differently" % aimed_differences)
	print("500 packets with a bad Godot value inside: same answer from both")


func _check_oversized_list() -> void:
	var values: Array = []
	for i in 300:
		values.append(i)
	var buffer := NetPackets.new_buffer()
	NetPackets.write_list(buffer, values, [])
	_codec.begin_write()
	_codec.write_list(values, [])
	_check(_codec.get_written() == buffer.data_array, "a list over the 255 limit is cut the same way")


func _check_world() -> void:
	# Claude 2026-11-07: was 37. Health (1 to 100) now takes 2 bytes instead of 5, as an INT8.
	_check(_world_bytes.size() == PAWNS * 34, "the test world is 34 bytes a pawn")
	_check(_write_per_list() == _world_bytes, "whole world, one call per list: same bytes")
	_check(_write_native() == _world_bytes, "whole world, one call: same bytes")
	_check(_tuned_write() == _world_bytes, "whole world, tuned GDScript: same bytes")

	var expected: Variant = _read_gdscript()
	_check(expected != null and expected.size() == PAWNS, "reading, NetPackets: the whole world")
	_check(_same_worlds(expected, _read_per_list()), "reading, one call per list: same values")
	_check(_same_worlds(expected, _codec.read_world(_world_bytes, 0, PAWNS)), "reading, one call: same values")
	_check(_same_worlds(expected, _tuned_read(_world_bytes, PAWNS)), "reading, tuned GDScript: same values")

	# A snapshot has a header in front, and the game hands over where the entities start.
	var with_header := PackedByteArray([9, 9, 9])
	with_header.append_array(_world_bytes)
	_check(_same_worlds(expected, _codec.read_world(with_header, 3, PAWNS)), "reading, one call: starts where it's told")

	# Broken snapshots: both must refuse the same ones.
	var differences := 0
	for cut_at in [0, 1, 3, 4, 5, 36, 37, 38, 40, 200, _world_bytes.size() - 1]:
		var part := _world_bytes.slice(0, cut_at)
		var script_answer: Variant = NetPackets.read_world(NetPackets.reader(part), PAWNS)
		if _codec.read_world(part, 0, PAWNS) != null or script_answer != null:
			differences += 1
	_check(differences == 0, "reading, one call: refuses a snapshot that's too short, like NetPackets")
	_check(_codec.read_world(_world_bytes, 0, 65535) == null, "reading, one call: refuses a count the bytes can't hold")
	_check(_codec.read_world(_world_bytes, -1, 1) == null and _codec.read_world(_world_bytes, _world_bytes.size() + 1, 0) == null, "reading, one call: refuses a start outside the bytes")
	_check(_same_lists(_codec.read_world(_world_bytes, _world_bytes.size(), 0), NetPackets.read_world(NetPackets.reader(_world_bytes), 0)), "reading, one call: no entities gives an empty list")
	var damaged := _world_bytes.duplicate()
	damaged[5] = 200 # not a tag
	_check(_codec.read_world(damaged, 0, PAWNS) == null and NetPackets.read_world(NetPackets.reader(damaged), PAWNS) == null, "reading, one call: refuses an unknown tag, like NetPackets")
	_check(NetPackets.write_world(_entries.slice(0, 7)).is_empty() and _codec.write_world(_entries.slice(0, 7)).is_empty(), "writing: an incomplete entry writes nothing, in both")


func _same_worlds(a: Variant, b: Variant) -> bool:
	if a == null or b == null or a.size() != b.size():
		return false
	for i in a.size():
		if a[i][0] != b[i][0]:
			return false
		for part in range(1, 5):
			if not _same_lists(a[i][part], b[i][part]):
				return false
	return true


# --- The test world --------------------------------------------------------------------------------

func _make_world() -> void:
	for i in PAWNS:
		var position := Vector3(_rng.randf_range(-200, 200), _rng.randf_range(0, 30), _rng.randf_range(-200, 200)).snapped(MM_VECTOR)
		var velocity := Vector3(_rng.randf_range(-6, 6), _rng.randf_range(-3, 3), _rng.randf_range(-6, 6)).snapped(MM_VECTOR)
		var yaw: float = StateEncoding.quantize(_rng.randf_range(-PI, PI), StateEncoding.ANGLE_U16)
		var grounded := _rng.randf() < 0.8
		var health := _rng.randi_range(1, 100)
		_ids.append(1000 + i)
		_states.append([position, velocity, yaw, grounded])
		_syncs.append([health])
	_entries.resize(PAWNS * NetPackets.WORLD_ENTRY_SIZE)
	_world_bytes = _write_gdscript()


# --- The ways of writing a world -------------------------------------------------------------------

## Gathering is part of a snapshot, so it's in every timing that needs it.
func _fill_entries() -> void:
	var at := 0
	for i in PAWNS:
		_entries[at] = _ids[i]
		_entries[at + 1] = _states[i]
		_entries[at + 2] = _state_encodings
		_entries[at + 3] = _syncs[i]
		_entries[at + 4] = _sync_encodings
		_entries[at + 5] = _empty
		_entries[at + 6] = _input_encodings
		_entries[at + 7] = _empty
		at += NetPackets.WORLD_ENTRY_SIZE


func _write_gdscript() -> PackedByteArray:
	_fill_entries()
	return NetPackets.write_world(_entries)


func _write_native() -> PackedByteArray:
	_fill_entries()
	return _codec.write_world(_entries)


func _write_per_list() -> PackedByteArray:
	_codec.begin_write()
	for i in PAWNS:
		_codec.write_u32(_ids[i])
		_codec.write_list(_states[i], _state_encodings)
		_codec.write_list(_syncs[i], _sync_encodings)
		_codec.write_list(_empty, _input_encodings)
		_codec.write_list(_empty, _empty)
	return _codec.get_written()


## GDScript written for speed: no StreamPeerBuffer, no looking up encodings by name. It only knows the four kinds of value this
## pawn uses. A real version would need the rest as well, so this is slightly better than GDScript could really do.
func _tuned_write() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(PAWNS * 40)
	var at := 0
	for i in PAWNS:
		out.encode_u32(at, _ids[i])
		at = _tuned_write_list(out, at + 4, _states[i], _state_kinds)
		at = _tuned_write_list(out, at, _syncs[i], _sync_kinds)
		out.encode_u8(at, 0)
		out.encode_u8(at + 1, 0)
		at += 2
	return out.slice(0, at)


func _tuned_write_list(out: PackedByteArray, start: int, values: Array, kinds: PackedByteArray) -> int:
	var at := start
	var count := values.size()
	out.encode_u8(at, count)
	at += 1
	for i in count:
		var kind := kinds[i]
		if kind == KIND_VECTOR3_MM:
			var v: Vector3 = values[i]
			var x := clampi(roundi(v.x / StateEncoding.MM), -INT24_LIMIT, INT24_LIMIT)
			var y := clampi(roundi(v.y / StateEncoding.MM), -INT24_LIMIT, INT24_LIMIT)
			var z := clampi(roundi(v.z / StateEncoding.MM), -INT24_LIMIT, INT24_LIMIT)
			out.encode_u8(at, NetPackets.Tag.VECTOR3_MM)
			out.encode_u16(at + 1, x & 0xFFFF)
			out.encode_s8(at + 3, x >> 16)
			out.encode_u16(at + 4, y & 0xFFFF)
			out.encode_s8(at + 6, y >> 16)
			out.encode_u16(at + 7, z & 0xFFFF)
			out.encode_s8(at + 9, z >> 16)
			at += 10
		elif kind == KIND_ANGLE_U16:
			var steps := roundi(wrapf(values[i], -PI, PI) / StateEncoding.U16_STEP)
			out.encode_u8(at, NetPackets.Tag.ANGLE_U16)
			out.encode_s16(at + 1, steps - 65536 if steps >= 32768 else steps)
			at += 3
		elif kind == KIND_BOOL:
			out.encode_u8(at, NetPackets.Tag.BOOL_TRUE if values[i] else NetPackets.Tag.BOOL_FALSE)
			at += 1
		elif values[i] >= -128 and values[i] <= 127: # Claude 2026-11-07: small ints, the same sizes NetPackets picks
			out.encode_u8(at, NetPackets.Tag.INT8)
			out.encode_s8(at + 1, values[i])
			at += 2
		elif values[i] >= -32768 and values[i] <= 32767:
			out.encode_u8(at, NetPackets.Tag.INT16)
			out.encode_s16(at + 1, values[i])
			at += 3
		else:
			out.encode_u8(at, NetPackets.Tag.INT32)
			out.encode_s32(at + 1, values[i])
			at += 5
	return at


# --- The ways of reading a world -------------------------------------------------------------------

func _read_gdscript() -> Variant:
	return NetPackets.read_world(NetPackets.reader(_world_bytes), PAWNS)


func _read_per_list() -> Variant:
	_codec.begin_read(_world_bytes)
	var parsed: Array = []
	for i in PAWNS:
		if _codec.get_available_bytes() < 4:
			return null
		var id := _codec.read_u32()
		var state: Variant = _codec.read_list()
		var sync: Variant = _codec.read_list()
		var input: Variant = _codec.read_list()
		var custom: Variant = _codec.read_list()
		if state == null or sync == null or input == null or custom == null:
			return null
		parsed.append([id, state, sync, input, custom])
	return parsed


func _tuned_read(data: PackedByteArray, count: int) -> Variant:
	var at := 0
	var size := data.size()
	var parsed: Array = []
	parsed.resize(count)
	for e in count:
		if at + 4 > size:
			return null
		var item: Array = [data.decode_u32(at), null, null, null, null]
		at += 4
		for part in range(1, 5):
			if at >= size:
				return null
			var list_size := data.decode_u8(at)
			at += 1
			var values: Array = []
			values.resize(list_size)
			for i in list_size:
				if at >= size:
					return null
				var tag := data.decode_u8(at)
				at += 1
				if tag == NetPackets.Tag.VECTOR3_MM:
					if at + 9 > size:
						return null
					var x := (data.decode_u16(at) + data.decode_s8(at + 2) * 65536) * StateEncoding.MM
					var y := (data.decode_u16(at + 3) + data.decode_s8(at + 5) * 65536) * StateEncoding.MM
					var z := (data.decode_u16(at + 6) + data.decode_s8(at + 8) * 65536) * StateEncoding.MM
					values[i] = Vector3(x, y, z).snapped(MM_VECTOR)
					at += 9
				elif tag == NetPackets.Tag.ANGLE_U16:
					if at + 2 > size:
						return null
					values[i] = Vector2(data.decode_s16(at) * StateEncoding.U16_STEP, 0.0).x
					at += 2
				elif tag == NetPackets.Tag.BOOL_TRUE:
					values[i] = true
				elif tag == NetPackets.Tag.BOOL_FALSE:
					values[i] = false
				elif tag == NetPackets.Tag.INT8: # Claude 2026-11-07
					if at + 1 > size:
						return null
					values[i] = data.decode_s8(at)
					at += 1
				elif tag == NetPackets.Tag.INT16: # Claude 2026-11-07
					if at + 2 > size:
						return null
					values[i] = data.decode_s16(at)
					at += 2
				elif tag == NetPackets.Tag.INT32:
					if at + 4 > size:
						return null
					values[i] = data.decode_s32(at)
					at += 4
				else:
					return null
			item[part] = values
		parsed[e] = item
	return parsed


# --- Part two: timings -----------------------------------------------------------------------------

func _print_timings() -> void:
	var writers: Array = [
		["GDScript (NetPackets, the fallback)", _write_gdscript],
		["GDScript tuned for speed", _tuned_write],
		["C++, one call per list", _write_per_list],
		["C++, one call for the world (what the game uses)", _write_native],
	]
	var readers: Array = [
		["GDScript (NetPackets, the fallback)", _read_gdscript],
		["GDScript tuned for speed", func() -> Variant: return _tuned_read(_world_bytes, PAWNS)],
		["C++, one call per list", _read_per_list],
		["C++, one call for the world (what the game uses)", func() -> Variant: return _codec.read_world(_world_bytes, 0, PAWNS)],
	]
	print("Writing a snapshot, %d bytes a pawn, microseconds per pawn:" % (_world_bytes.size() / PAWNS))
	_print_group(_time_group(writers))
	print("")
	print("Reading a snapshot, microseconds per pawn:")
	_print_group(_time_group(readers))


## Takes turns between the versions, so a slow moment on the computer lands on all of them rather than on one.
func _time_group(versions: Array) -> Array:
	var samples: Array = []
	for version: Array in versions:
		samples.append([])
	for timing in TIMINGS + 1:
		for v in versions.size():
			var work: Callable = versions[v][1]
			var started := Time.get_ticks_usec()
			for round_number in ROUNDS_PER_TIMING:
				work.call()
			if timing > 0: # the first pass only warms things up
				samples[v].append(float(Time.get_ticks_usec() - started) / (ROUNDS_PER_TIMING * PAWNS))
	var results: Array = []
	for v in versions.size():
		samples[v].sort()
		results.append([versions[v][0], samples[v][TIMINGS / 2], samples[v][0], samples[v][TIMINGS - 1]])
	return results


func _print_group(results: Array) -> void:
	var baseline: float = results[0][1]
	print("     middle   (fastest - slowest)   vs NetPackets")
	for result: Array in results:
		print("  %7.2f us   (%6.2f - %6.2f)    %5.1fx   %s" % [result[1], result[2], result[3], baseline / result[1], result[0]])
