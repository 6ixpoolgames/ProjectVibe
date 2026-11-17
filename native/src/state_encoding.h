// Written by Claude (claude-opus-5-5), 2026-11-17. History: native/CHANGELOG.md.
// The encoding rules the packet codec (net_codec.cpp) and the rollback recorder (tick_state_recorder.cpp) share, written once:
// the rounding steps, the encoding names and one list of encoding numbers. Not seen by GDScript.
//
// These copy the GDScript side, and must stay the same as it:
//   - MM, CM, U16_STEP and BYTE_STEP are StateEncoding.gd's (and NetPackets.gd's) constants. GDScript numbers are 64-bit doubles.
//   - The names are the encodings a TickStateComponent entry can pick in the inspector ("auto", "vector3_mm", ...).
// The numbers in Encoding are only used inside the C++ library. They're never sent or saved, so they can be reordered freely.
#pragma once

#include <godot_cpp/variant/string_name.hpp>

namespace state_encoding {

// Rounding steps: a millimetre, a centimetre, and a full turn split into 65536 or 256 steps.
constexpr double MM = 0.001;
constexpr double CM = 0.01;
constexpr double PI_VALUE = 3.14159265358979323846;
constexpr double TAU_VALUE = 6.28318530717958647692;
constexpr double U16_STEP = TAU_VALUE / 65536.0;
constexpr double BYTE_STEP = TAU_VALUE / 256.0;

// One number per encoding name. ENC_UNKNOWN is a name that isn't one of them.
enum Encoding : int {
	ENC_UNKNOWN = -1,
	ENC_AUTO = 0, // "auto": picked from the value's type when it's written
	ENC_RAW, // "raw": sent as it is, never rounded
	ENC_VECTOR3_MM,
	ENC_VECTOR2_MM,
	ENC_VECTOR3_CM,
	ENC_ANGLE_U16,
	ENC_ANGLE_BYTE,
	ENC_FLOAT,
};

// Turns an encoding name into its number. Godot's StringNames are compared by pointer, which is quick, but they can only be made
// once the engine has started, so each class that needs them keeps one of these as a member instead of a global.
class EncodingNames {
public:
	EncodingNames() :
			m_auto("auto"),
			m_raw("raw"),
			m_vector3_mm("vector3_mm"),
			m_vector2_mm("vector2_mm"),
			m_vector3_cm("vector3_cm"),
			m_angle_u16("angle_u16"),
			m_angle_byte("angle_byte"),
			m_float("float") {}

	Encoding id_of(const godot::StringName &name) const {
		// The commonest first: positions, angles and floats.
		if (name == m_vector3_mm) {
			return ENC_VECTOR3_MM;
		}
		if (name == m_angle_u16) {
			return ENC_ANGLE_U16;
		}
		if (name == m_float) {
			return ENC_FLOAT;
		}
		if (name == m_auto) {
			return ENC_AUTO;
		}
		if (name == m_raw) {
			return ENC_RAW;
		}
		if (name == m_vector2_mm) {
			return ENC_VECTOR2_MM;
		}
		if (name == m_vector3_cm) {
			return ENC_VECTOR3_CM;
		}
		if (name == m_angle_byte) {
			return ENC_ANGLE_BYTE;
		}
		return ENC_UNKNOWN;
	}

private:
	godot::StringName m_auto;
	godot::StringName m_raw;
	godot::StringName m_vector3_mm;
	godot::StringName m_vector2_mm;
	godot::StringName m_vector3_cm;
	godot::StringName m_angle_u16;
	godot::StringName m_angle_byte;
	godot::StringName m_float;
};

} // namespace state_encoding
