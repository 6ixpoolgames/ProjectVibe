# Written by Claude (claude-opus-5-5), 2026-11-04. History: netcode/CHANGELOG.md.
## How precisely networked values are stored (netcode spec section 5.3).
##
## Every networked property has an encoding. Values are rounded to it at the end of every tick, on server and client alike, so both
## simulate from exactly what the network can carry. Encodings: [code]auto[/code] (by type), [code]vector3_mm[/code] (default for
## positions), [code]vector2_mm[/code], [code]vector3_cm[/code], [code]angle_u16[/code], [code]angle_byte[/code], [code]float[/code],
## [code]raw[/code] (ints, bools, StringNames).
## [br]Twin: the C++ recorder and codec round the same way ([code]native/src/state_encoding.h[/code]); a change to [method quantize]
## goes in both.
## Design: netcode spec 5.3.
class_name StateEncoding
extends RefCounted

## Picks by the value's type: Vector3 is vector3_mm, Vector2 is vector2_mm, float is float, anything else raw.
const AUTO := &"auto"
## 1 mm per axis. The default for positions and velocities.
const VECTOR3_MM := &"vector3_mm"
## The same, for a Vector2.
const VECTOR2_MM := &"vector2_mm"
## 1 cm per axis. Only for values that don't build up tick by tick (a target point).
const VECTOR3_CM := &"vector3_cm"
## An angle in radians, 65536 steps per turn (about 0.005 degrees).
const ANGLE_U16 := &"angle_u16"
## An angle in radians, 256 steps per turn. Only for values that don't build up tick by tick.
const ANGLE_BYTE := &"angle_byte"
## A 32-bit float.
const FLOAT := &"float"
## Left alone: ints, bools, bitmasks, StringNames.
const RAW := &"raw"

## One millimetre, the step of the mm encodings.
const MM := 0.001
## One centimetre, the step of vector3_cm.
const CM := 0.01
## The angle_u16 step in radians.
const U16_STEP := TAU / 65536.0
## The angle_byte step in radians.
const BYTE_STEP := TAU / 256.0
## How close two floats must be to count as the same state.
const FLOAT_TOLERANCE := 0.0001


## True if this is one of the encoding names above.
static func is_known(encoding: StringName) -> bool:
	return encoding in [AUTO, VECTOR3_MM, VECTOR2_MM, VECTOR3_CM, ANGLE_U16, ANGLE_BYTE, FLOAT, RAW]


## Turns auto into a concrete encoding, from the value's type.
static func resolve(encoding: StringName, value: Variant) -> StringName:
	if encoding != AUTO:
		return encoding
	match typeof(value):
		TYPE_VECTOR3:
			return VECTOR3_MM
		TYPE_VECTOR2:
			return VECTOR2_MM
		TYPE_FLOAT:
			return FLOAT
	return RAW


## The value rounded to its encoding (twin of the C++ [code]state_encoding.h[/code]; change both). Rounding a rounded value changes nothing.
static func quantize(value: Variant, encoding: StringName) -> Variant:
	match encoding:
		VECTOR3_MM:
			if value is Vector3:
				return value.snapped(Vector3(MM, MM, MM))
		VECTOR2_MM:
			if value is Vector2:
				return value.snapped(Vector2(MM, MM))
		VECTOR3_CM:
			if value is Vector3:
				return value.snapped(Vector3(CM, CM, CM))
		ANGLE_U16:
			if value is float:
				return as_float32(snappedf(wrapf(value, -PI, PI), U16_STEP))
		ANGLE_BYTE:
			if value is float:
				return as_float32(snappedf(wrapf(value, -PI, PI), BYTE_STEP))
		FLOAT:
			if value is float:
				return as_float32(value)
	return value


## The float rounded to 32 bits, as engine properties like rotation store it, so it reads back exactly as written. NetPackets uses it too.
static func as_float32(value: float) -> float:
	return Vector2(value, 0.0).x


## A value part way between two others, for drawing between snapshots. Things that can't blend (bools) stay at the first.
static func blend(a: Variant, b: Variant, weight: float, encoding: StringName) -> Variant:
	if typeof(a) != typeof(b):
		return a
	match typeof(a):
		TYPE_VECTOR3, TYPE_VECTOR2:
			return a.lerp(b, weight)
		TYPE_FLOAT:
			if encoding == ANGLE_U16 or encoding == ANGLE_BYTE:
				return lerp_angle(a, b, weight)
			return lerpf(a, b, weight)
	return a


## A copy sharing nothing with the original. Gotcha: arrays, dictionaries and packed arrays are held by reference, so history slots must copy.
static func copy_value(value: Variant) -> Variant:
	var type := typeof(value)
	if type == TYPE_ARRAY or type == TYPE_DICTIONARY:
		return value.duplicate(true)
	if type >= TYPE_PACKED_BYTE_ARRAY and type < TYPE_MAX:
		return value.duplicate()
	return value


## True if two values count as the same state; reconciliation uses it to decide whether a prediction was right.
static func nearly_equal(a: Variant, b: Variant, encoding: StringName) -> bool:
	if typeof(a) != typeof(b):
		return false
	match encoding:
		VECTOR3_MM, VECTOR2_MM:
			return (a - b).length() <= MM * 1.5
		VECTOR3_CM:
			return (a - b).length() <= CM * 1.5
		ANGLE_U16:
			return absf(angle_difference(a, b)) <= U16_STEP * 1.5
		ANGLE_BYTE:
			return absf(angle_difference(a, b)) <= BYTE_STEP * 1.5
		FLOAT:
			return absf(a - b) <= FLOAT_TOLERANCE
	return a == b
