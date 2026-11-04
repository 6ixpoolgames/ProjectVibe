## Written by Claude (claude-opus-5-5), 2026-11-04: what goes on the wire (netcode spec section 11).
## Packet types, and how one value is turned into bytes and back. Every value starts with a one-byte tag saying how it's
## stored, so a reader never has to guess, and a bad packet can be spotted and dropped.
##
## Values follow their encoding from StateEncoding: a position at 1 mm takes 3 bytes per axis, an angle_u16 takes 2.
## Reading a rounded value back gives exactly the same number the sender rounded to, which is why a client's prediction
## can compare equal to what the server sent.
##
## Never trust these bytes: read_value returns BAD for anything truncated or unknown, and objects are never decoded.
## Positions are limited to about +/- 8.3 km at 1 mm; anything further is clamped.
class_name NetPackets
extends RefCounted

## Bump this when the wire format changes. It's part of the handshake's content hash.
const PROTOCOL_VERSION := 3

enum Type { HELLO = 1, WELCOME, REFUSED, PING, PONG, SPAWN, DESPAWN, INPUT, SNAPSHOT, DEBUG_SWITCH }

## What read_value returns for a broken packet. Stop reading when you see it.
const BAD := &"__net_bad_packet__"
const MAX_LIST_SIZE := 255
const INT24_LIMIT := 8388607

enum Tag { MISSING = 0, VECTOR3_MM, VECTOR3_CM, VECTOR2_MM, ANGLE_U16, ANGLE_BYTE, FLOAT32, BOOL_FALSE, BOOL_TRUE, INT32, INT64, OTHER }


static func new_buffer() -> StreamPeerBuffer:
	var buffer := StreamPeerBuffer.new()
	return buffer


static func reader(bytes: PackedByteArray) -> StreamPeerBuffer:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	return buffer


static func has_bytes(buffer: StreamPeerBuffer, count: int) -> bool:
	return buffer.get_available_bytes() >= count


# --- One value -------------------------------------------------------------------------------------

## Writes a value using its encoding. TickStateComponent.MISSING becomes a one-byte "nothing here".
static func write_value(buffer: StreamPeerBuffer, value: Variant, encoding: StringName) -> void:
	if is_same(value, TickStateComponent.MISSING) or value == null:
		buffer.put_u8(Tag.MISSING)
		return
	var used := StateEncoding.resolve(encoding, value)
	match used:
		StateEncoding.VECTOR3_MM:
			if value is Vector3:
				_put_vector3(buffer, Tag.VECTOR3_MM, value, StateEncoding.MM)
				return
		StateEncoding.VECTOR3_CM:
			if value is Vector3:
				_put_vector3(buffer, Tag.VECTOR3_CM, value, StateEncoding.CM)
				return
		StateEncoding.VECTOR2_MM:
			if value is Vector2:
				buffer.put_u8(Tag.VECTOR2_MM)
				_put_int24(buffer, roundi(value.x / StateEncoding.MM))
				_put_int24(buffer, roundi(value.y / StateEncoding.MM))
				return
		StateEncoding.ANGLE_U16:
			if value is float:
				buffer.put_u8(Tag.ANGLE_U16)
				buffer.put_16(_wrap_steps(roundi(wrapf(value, -PI, PI) / StateEncoding.U16_STEP), 32768))
				return
		StateEncoding.ANGLE_BYTE:
			if value is float:
				buffer.put_u8(Tag.ANGLE_BYTE)
				buffer.put_8(_wrap_steps(roundi(wrapf(value, -PI, PI) / StateEncoding.BYTE_STEP), 128))
				return
		StateEncoding.FLOAT:
			if value is float:
				buffer.put_u8(Tag.FLOAT32)
				buffer.put_float(value)
				return
	_write_plain(buffer, value)


## Reads one value, or returns BAD. Vectors and angles come back exactly as StateEncoding.quantize would round them.
static func read_value(buffer: StreamPeerBuffer) -> Variant:
	if not has_bytes(buffer, 1):
		return BAD
	var tag := buffer.get_u8()
	match tag:
		Tag.MISSING:
			return TickStateComponent.MISSING
		Tag.VECTOR3_MM:
			return _get_vector3(buffer, StateEncoding.MM, StateEncoding.VECTOR3_MM)
		Tag.VECTOR3_CM:
			return _get_vector3(buffer, StateEncoding.CM, StateEncoding.VECTOR3_CM)
		Tag.VECTOR2_MM:
			if not has_bytes(buffer, 6):
				return BAD
			var x := _get_int24(buffer) * StateEncoding.MM
			var y := _get_int24(buffer) * StateEncoding.MM
			return StateEncoding.quantize(Vector2(x, y), StateEncoding.VECTOR2_MM)
		Tag.ANGLE_U16:
			if not has_bytes(buffer, 2):
				return BAD
			return StateEncoding._as_float32(buffer.get_16() * StateEncoding.U16_STEP)
		Tag.ANGLE_BYTE:
			if not has_bytes(buffer, 1):
				return BAD
			return StateEncoding._as_float32(buffer.get_8() * StateEncoding.BYTE_STEP)
		Tag.FLOAT32:
			if not has_bytes(buffer, 4):
				return BAD
			return float(buffer.get_float())
		Tag.BOOL_FALSE:
			return false
		Tag.BOOL_TRUE:
			return true
		Tag.INT32:
			if not has_bytes(buffer, 4):
				return BAD
			return buffer.get_32()
		Tag.INT64:
			if not has_bytes(buffer, 8):
				return BAD
			return buffer.get_64()
		Tag.OTHER:
			# get_var refuses to build objects when allow_objects is false, so this can't run anything. It does allocate
			# whatever length the packet claims, so that's checked first: a forged length could ask for gigabytes.
			if not has_bytes(buffer, 4):
				return BAD
			var start := buffer.get_position()
			var claimed := buffer.get_32()
			buffer.seek(start)
			if claimed < 0 or not has_bytes(buffer, 4 + claimed):
				return BAD
			return buffer.get_var(false)
	return BAD


# --- A list of values ------------------------------------------------------------------------------

## Writes a count, then each value with its encoding. values and encodings must be the same size.
static func write_list(buffer: StreamPeerBuffer, values: Array, encodings: Array) -> void:
	var count := mini(values.size(), MAX_LIST_SIZE)
	buffer.put_u8(count)
	for i in count:
		var encoding: StringName = encodings[i] if i < encodings.size() else StateEncoding.AUTO
		write_value(buffer, values[i], encoding)


## Reads a list. Returns null if the packet is broken.
static func read_list(buffer: StreamPeerBuffer) -> Variant:
	if not has_bytes(buffer, 1):
		return null
	var count := buffer.get_u8()
	var values: Array = []
	values.resize(count)
	for i in count:
		var value: Variant = read_value(buffer)
		if is_same(value, BAD):
			return null
		values[i] = value
	return values


# --- Internals -------------------------------------------------------------------------------------

static func _write_plain(buffer: StreamPeerBuffer, value: Variant) -> void:
	match typeof(value):
		TYPE_BOOL:
			buffer.put_u8(Tag.BOOL_TRUE if value else Tag.BOOL_FALSE)
		TYPE_INT:
			if value >= -2147483648 and value <= 2147483647:
				buffer.put_u8(Tag.INT32)
				buffer.put_32(value)
			else:
				buffer.put_u8(Tag.INT64)
				buffer.put_64(value)
		TYPE_FLOAT:
			buffer.put_u8(Tag.FLOAT32)
			buffer.put_float(value)
		TYPE_OBJECT:
			buffer.put_u8(Tag.MISSING) # objects never go over the wire
		_:
			buffer.put_u8(Tag.OTHER)
			buffer.put_var(value, false)


## An angle rounded to the very end of its range would need one more step than the bytes hold. It's the same direction
## as the other end, so it wraps.
static func _wrap_steps(steps: int, half_range: int) -> int:
	return steps - 2 * half_range if steps >= half_range else steps


static func _put_vector3(buffer: StreamPeerBuffer, tag: int, value: Vector3, step: float) -> void:
	buffer.put_u8(tag)
	_put_int24(buffer, roundi(value.x / step))
	_put_int24(buffer, roundi(value.y / step))
	_put_int24(buffer, roundi(value.z / step))


## Rounded again on arrival, because engine vectors store 32 bits: this gives the very same number the sender rounded to.
static func _get_vector3(buffer: StreamPeerBuffer, step: float, encoding: StringName) -> Variant:
	if not has_bytes(buffer, 9):
		return BAD
	var x := _get_int24(buffer) * step
	var y := _get_int24(buffer) * step
	var z := _get_int24(buffer) * step
	return StateEncoding.quantize(Vector3(x, y, z), encoding)


static func _put_int24(buffer: StreamPeerBuffer, value: int) -> void:
	var clamped := clampi(value, -INT24_LIMIT, INT24_LIMIT)
	buffer.put_u8(clamped & 0xFF)
	buffer.put_u8((clamped >> 8) & 0xFF)
	buffer.put_u8((clamped >> 16) & 0xFF)


static func _get_int24(buffer: StreamPeerBuffer) -> int:
	var low := buffer.get_u8()
	var middle := buffer.get_u8()
	var high := buffer.get_u8()
	var value := low | (middle << 8) | (high << 16)
	return value - (1 << 24) if value >= (1 << 23) else value
