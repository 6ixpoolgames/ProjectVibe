## Written by Claude (claude-opus-5-5), 2026-11-04: how precisely networked values are stored (netcode spec section 5.3).
## Every networked property has an encoding. Values are rounded to it at the end of every tick, on server and client
## alike, so both simulate from exactly what the network can carry and rounding alone never causes a misprediction.
##
## Encodings:
##   auto        pick by the value's type: Vector3 -> vector3_mm, Vector2 -> vector2_mm, float -> float, anything else -> raw
##   vector3_mm  1 mm per axis. The default for positions AND velocities
##   vector2_mm  same, Vector2
##   vector3_cm  1 cm per axis. Only for values that don't build up tick by tick (a target point, say)
##   angle_u16   an angle in radians, 65536 steps per turn (about 0.005 degrees)
##   angle_byte  an angle in radians, 256 steps per turn. Only for values that don't build up tick by tick
##   float       32-bit float
##   raw         left alone: ints, bools, bitmasks, StringNames
##
## Why rounding step matters: a value that changes by less than half a step per tick is rounded straight back and
## never changes. At 60 ticks/s and 1 mm, that stalls anything moving slower than about 3 cm/s, and speeds in general
## are off by up to 3 cm/s. At 1 cm it would be 30 cm/s, which is why positions aren't in cm.
##
## Physics bodies, two rules (see TickSamplePawn.gd):
##   - safe_margin must not be a whole number of steps, and Godot's default of 1 mm is. A body rests one margin above the
##     floor, so rounding would park it exactly on the edge of "touching". Float noise then flips the contact, and the
##     engine snaps it up to 2.4 cm into the floor.
##   - Don't turn the body by writing rotation every tick. That slowly changes its scale, and so its collision shape,
##     differently in a replay. Keep facing as a plain number and turn only the model.
##
## Corner cases (checked in tests/tick_state_selftest.gd): an encoding that doesn't fit the value's type leaves the
## value unchanged; an unknown encoding name is reported by is_known() and the component falls back to auto.
class_name StateEncoding
extends RefCounted

const AUTO := &"auto"
const VECTOR3_MM := &"vector3_mm"
const VECTOR2_MM := &"vector2_mm"
const VECTOR3_CM := &"vector3_cm"
const ANGLE_U16 := &"angle_u16"
const ANGLE_BYTE := &"angle_byte"
const FLOAT := &"float"
const RAW := &"raw"

const MM := 0.001
const CM := 0.01
const U16_STEP := TAU / 65536.0
const BYTE_STEP := TAU / 256.0
const FLOAT_TOLERANCE := 0.0001


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


## The value rounded to its encoding. Rounding an already rounded value changes nothing.
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
				return _as_float32(snappedf(wrapf(value, -PI, PI), U16_STEP))
		ANGLE_BYTE:
			if value is float:
				return _as_float32(snappedf(wrapf(value, -PI, PI), BYTE_STEP))
		FLOAT:
			if value is float:
				return _as_float32(value)
	return value


## GDScript floats are 64-bit, but engine properties like rotation store 32 bits. Rounded values go through this so a
## value reads back from such a property exactly as it was written, and doesn't look changed on the next tick.
static func _as_float32(value: float) -> float:
	return Vector2(value, 0.0).x


## A copy of the value that shares nothing with the original. Arrays, Dictionaries and packed arrays are held by
## reference in GDScript, so saving one without copying would leave every history slot pointing at the same live object.
static func copy_value(value: Variant) -> Variant:
	var type := typeof(value)
	if type == TYPE_ARRAY or type == TYPE_DICTIONARY:
		return value.duplicate(true)
	if type >= TYPE_PACKED_BYTE_ARRAY and type < TYPE_MAX:
		return value.duplicate()
	return value


## True if two values count as the same state. Reconciliation uses this to decide whether a prediction was right.
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
