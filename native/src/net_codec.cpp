// Written by Claude (claude-opus-5-5), 2026-11-05: see net_codec.h. Every rule here copies assets/scripts/netcode/NetPackets.gd,
// and tests/net_codec_selftest fails if the two ever give different bytes or values. Change them together.
#include "net_codec.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>
#include <cstring>

using namespace godot;

namespace {

// The same numbers as NetPackets.Tag.
enum Tag : uint8_t {
	TAG_MISSING = 0,
	TAG_VECTOR3_MM,
	TAG_VECTOR3_CM,
	TAG_VECTOR2_MM,
	TAG_ANGLE_U16,
	TAG_ANGLE_BYTE,
	TAG_FLOAT32,
	TAG_BOOL_FALSE,
	TAG_BOOL_TRUE,
	TAG_INT32,
	TAG_INT64,
	TAG_OTHER,
	// Claude 2026-11-07: small ints in 1 or 2 bytes instead of 4. Added at the end so the numbers above don't move.
	TAG_INT8,
	TAG_INT16,
};

enum Encoding : uint8_t {
	ENC_AUTO = 0,
	ENC_VECTOR3_MM,
	ENC_VECTOR3_CM,
	ENC_VECTOR2_MM,
	ENC_ANGLE_U16,
	ENC_ANGLE_BYTE,
	ENC_FLOAT,
	ENC_RAW,
};

const int64_t PROTOCOL_VERSION = 5; // the same as NetPackets.PROTOCOL_VERSION: bump both when the format changes. Claude 2026-11-07: 5 adds small ints
const int64_t WORLD_ENTRY_SIZE = 8; // the same as NetPackets.WORLD_ENTRY_SIZE
const int64_t MAX_LIST_SIZE = 255;
const int64_t INT24_LIMIT = 8388607;
const double MM = 0.001;
const double CM = 0.01;
const double PI_VALUE = 3.14159265358979323846;
const double TAU_VALUE = 6.28318530717958647692;
const double U16_STEP = TAU_VALUE / 65536.0;
const double BYTE_STEP = TAU_VALUE / 256.0;

// The engine's own wrapf and roundi. godot-cpp's Math::wrapf is 32-bit and leaves out the check at the top of the range, so
// using it could round an angle differently from GDScript.
bool engine_is_equal_approx(float a, float b) {
	if (a == b) {
		return true;
	}
	float tolerance = 0.00001f * std::fabs(a);
	if (tolerance < 0.00001f) {
		tolerance = 0.00001f;
	}
	return std::fabs(a - b) < tolerance;
}

double engine_wrapf(double value, double min, double max) {
	const double range = max - min;
	const double result = value - (range * std::floor((value - min) / range));
	return engine_is_equal_approx((float)result, (float)max) ? min : result;
}

int64_t engine_roundi(double value) {
	return (int64_t)std::round(value);
}

// An angle rounded to the very end of its range wraps to the other end, the same direction.
int64_t wrap_steps(int64_t steps, int64_t half_range) {
	return steps >= half_range ? steps - 2 * half_range : steps;
}

Vector3 rounded_vector3(double x, double y, double z, double step) {
	const float float_step = (float)step;
	return Vector3((float)x, (float)y, (float)z).snapped(Vector3(float_step, float_step, float_step));
}

} // namespace

NetCodec::NetCodec() :
		m_missing("__tick_state_missing__"),
		m_auto("auto"),
		m_vector3_mm("vector3_mm"),
		m_vector3_cm("vector3_cm"),
		m_vector2_mm("vector2_mm"),
		m_angle_u16("angle_u16"),
		m_angle_byte("angle_byte"),
		m_float("float") {}

int64_t NetCodec::get_protocol_version() const {
	return PROTOCOL_VERSION;
}

int NetCodec::encoding_id(const Variant &name) const {
	const StringName encoding = name;
	if (encoding == m_auto) {
		return ENC_AUTO;
	}
	if (encoding == m_vector3_mm) {
		return ENC_VECTOR3_MM;
	}
	if (encoding == m_angle_u16) {
		return ENC_ANGLE_U16;
	}
	if (encoding == m_float) {
		return ENC_FLOAT;
	}
	if (encoding == m_vector2_mm) {
		return ENC_VECTOR2_MM;
	}
	if (encoding == m_vector3_cm) {
		return ENC_VECTOR3_CM;
	}
	if (encoding == m_angle_byte) {
		return ENC_ANGLE_BYTE;
	}
	return ENC_RAW;
}

// --- Writing ---------------------------------------------------------------------------------------

void NetCodec::put_u8(uint8_t value) {
	m_written.push_back(value);
}

void NetCodec::put_u16(uint16_t value) {
	const size_t at = m_written.size();
	m_written.resize(at + 2);
	std::memcpy(m_written.data() + at, &value, 2); // the machines Godot targets here are little-endian, as StreamPeerBuffer writes
}

void NetCodec::put_u32(uint32_t value) {
	const size_t at = m_written.size();
	m_written.resize(at + 4);
	std::memcpy(m_written.data() + at, &value, 4);
}

void NetCodec::put_float(float value) {
	const size_t at = m_written.size();
	m_written.resize(at + 4);
	std::memcpy(m_written.data() + at, &value, 4);
}

void NetCodec::put_int24(int64_t value) {
	const int64_t clamped = value < -INT24_LIMIT ? -INT24_LIMIT : (value > INT24_LIMIT ? INT24_LIMIT : value);
	const size_t at = m_written.size();
	m_written.resize(at + 3);
	uint8_t *out = m_written.data() + at;
	out[0] = (uint8_t)(clamped & 0xFF);
	out[1] = (uint8_t)((clamped >> 8) & 0xFF);
	out[2] = (uint8_t)((clamped >> 16) & 0xFF);
}

void NetCodec::put_vector3(uint8_t tag, const Vector3 &value, double step) {
	put_u8(tag);
	put_int24(engine_roundi((double)value.x / step));
	put_int24(engine_roundi((double)value.y / step));
	put_int24(engine_roundi((double)value.z / step));
}

void NetCodec::put_angle_u16(double value) {
	put_u8(TAG_ANGLE_U16);
	put_u16((uint16_t)(int16_t)wrap_steps(engine_roundi(engine_wrapf(value, -PI_VALUE, PI_VALUE) / U16_STEP), 32768));
}

void NetCodec::put_int(int64_t value) {
	// Claude 2026-11-07: the smallest size that holds it. Most networked ints (held actions, counters, small ids) fit in one byte.
	if (value >= -128 && value <= 127) {
		put_u8(TAG_INT8);
		put_u8((uint8_t)(int8_t)value);
	} else if (value >= -32768 && value <= 32767) {
		put_u8(TAG_INT16);
		put_u16((uint16_t)(int16_t)value);
	} else if (value >= -2147483648LL && value <= 2147483647LL) {
		put_u8(TAG_INT32);
		put_u32((uint32_t)(int32_t)value);
	} else {
		put_u8(TAG_INT64);
		const size_t at = m_written.size();
		m_written.resize(at + 8);
		std::memcpy(m_written.data() + at, &value, 8);
	}
}

void NetCodec::write_plain(const Variant &value) {
	switch (value.get_type()) {
		case Variant::BOOL:
			put_u8((bool)value ? TAG_BOOL_TRUE : TAG_BOOL_FALSE);
			break;
		case Variant::INT:
			put_int((int64_t)value);
			break;
		case Variant::FLOAT:
			put_u8(TAG_FLOAT32);
			put_float((float)(double)value);
			break;
		case Variant::OBJECT:
			put_u8(TAG_MISSING); // objects never go over the wire
			break;
		default: {
			// A length, then Godot's own encoding: what StreamPeerBuffer.put_var writes.
			const PackedByteArray encoded = UtilityFunctions::var_to_bytes(value);
			put_u8(TAG_OTHER);
			put_u32((uint32_t)encoded.size());
			const size_t at = m_written.size();
			m_written.resize(at + encoded.size());
			if (encoded.size() > 0) {
				std::memcpy(m_written.data() + at, encoded.ptr(), encoded.size());
			}
		}
	}
}

void NetCodec::write_value(const Variant &value, int encoding) {
	const Variant::Type type = value.get_type();
	if (type == Variant::NIL || (type == Variant::STRING_NAME && (StringName)value == m_missing)) {
		put_u8(TAG_MISSING);
		return;
	}
	if (encoding == ENC_AUTO) {
		encoding = type == Variant::VECTOR3 ? ENC_VECTOR3_MM : (type == Variant::VECTOR2 ? ENC_VECTOR2_MM : (type == Variant::FLOAT ? ENC_FLOAT : ENC_RAW));
	}
	switch (encoding) {
		case ENC_VECTOR3_MM:
			if (type == Variant::VECTOR3) {
				put_vector3(TAG_VECTOR3_MM, value, MM);
				return;
			}
			break;
		case ENC_VECTOR3_CM:
			if (type == Variant::VECTOR3) {
				put_vector3(TAG_VECTOR3_CM, value, CM);
				return;
			}
			break;
		case ENC_VECTOR2_MM:
			if (type == Variant::VECTOR2) {
				const Vector2 v = value;
				put_u8(TAG_VECTOR2_MM);
				put_int24(engine_roundi((double)v.x / MM));
				put_int24(engine_roundi((double)v.y / MM));
				return;
			}
			break;
		case ENC_ANGLE_U16:
			if (type == Variant::FLOAT) {
				put_angle_u16((double)value);
				return;
			}
			break;
		case ENC_ANGLE_BYTE:
			if (type == Variant::FLOAT) {
				put_u8(TAG_ANGLE_BYTE);
				put_u8((uint8_t)(int8_t)wrap_steps(engine_roundi(engine_wrapf((double)value, -PI_VALUE, PI_VALUE) / BYTE_STEP), 128));
				return;
			}
			break;
		case ENC_FLOAT:
			if (type == Variant::FLOAT) {
				put_u8(TAG_FLOAT32);
				put_float((float)(double)value);
				return;
			}
			break;
		default:
			break;
	}
	write_plain(value);
}

void NetCodec::begin_write() {
	m_written.clear(); // keeps its memory, so later packets don't allocate
}

void NetCodec::write_u32(int64_t value) {
	put_u32((uint32_t)value);
}

void NetCodec::write_list(const Array &values, const Array &encodings) {
	const int64_t count = values.size() < MAX_LIST_SIZE ? values.size() : MAX_LIST_SIZE;
	put_u8((uint8_t)count);
	for (int64_t i = 0; i < count; i++) {
		write_value(values[i], i < encodings.size() ? encoding_id(encodings[i]) : (int)ENC_AUTO);
	}
}

PackedByteArray NetCodec::write_world(const Array &entries) {
	begin_write();
	const Array no_encodings;
	for (int64_t at = 0; at + WORLD_ENTRY_SIZE <= entries.size(); at += WORLD_ENTRY_SIZE) {
		put_u32((uint32_t)(int64_t)entries[at]);
		write_list(entries[at + 1], entries[at + 2]);
		write_list(entries[at + 3], entries[at + 4]);
		write_list(entries[at + 5], entries[at + 6]);
		write_list(entries[at + 7], no_encodings);
	}
	return get_written();
}

PackedByteArray NetCodec::get_written() const {
	PackedByteArray out;
	out.resize((int64_t)m_written.size());
	if (!m_written.empty()) {
		std::memcpy(out.ptrw(), m_written.data(), m_written.size());
	}
	return out;
}

// --- Reading ---------------------------------------------------------------------------------------

void NetCodec::begin_read(const PackedByteArray &bytes) {
	m_read_bytes = bytes;
	m_read = m_read_bytes.ptr();
	m_read_size = m_read_bytes.size();
	m_read_at = 0;
}

int64_t NetCodec::get_available_bytes() const {
	return m_read_size - m_read_at;
}

int64_t NetCodec::read_u32() {
	if (get_available_bytes() < 4) {
		return 0;
	}
	uint32_t value;
	std::memcpy(&value, m_read + m_read_at, 4);
	m_read_at += 4;
	return value;
}

int32_t NetCodec::get_int24() {
	const uint8_t *in = m_read + m_read_at;
	m_read_at += 3;
	const int32_t value = (int32_t)in[0] | ((int32_t)in[1] << 8) | ((int32_t)in[2] << 16);
	return value >= (1 << 23) ? value - (1 << 24) : value;
}

// False for anything truncated or unknown. Objects are never decoded, and a claimed length is checked before it's used.
bool NetCodec::read_value(Variant &out) {
	if (get_available_bytes() < 1) {
		return false;
	}
	const uint8_t tag = m_read[m_read_at];
	m_read_at += 1;
	switch (tag) {
		case TAG_MISSING:
			out = m_missing;
			return true;
		case TAG_VECTOR3_MM:
		case TAG_VECTOR3_CM: {
			if (get_available_bytes() < 9) {
				return false;
			}
			const double step = tag == TAG_VECTOR3_MM ? MM : CM;
			const double x = get_int24() * step;
			const double y = get_int24() * step;
			const double z = get_int24() * step;
			out = rounded_vector3(x, y, z, step);
			return true;
		}
		case TAG_VECTOR2_MM: {
			if (get_available_bytes() < 6) {
				return false;
			}
			const double x = get_int24() * MM;
			const double y = get_int24() * MM;
			const float step = (float)MM;
			out = Vector2((float)x, (float)y).snapped(Vector2(step, step));
			return true;
		}
		case TAG_ANGLE_U16: {
			if (get_available_bytes() < 2) {
				return false;
			}
			int16_t steps;
			std::memcpy(&steps, m_read + m_read_at, 2);
			m_read_at += 2;
			out = (double)(float)(steps * U16_STEP);
			return true;
		}
		case TAG_ANGLE_BYTE: {
			if (get_available_bytes() < 1) {
				return false;
			}
			const int8_t steps = (int8_t)m_read[m_read_at];
			m_read_at += 1;
			out = (double)(float)(steps * BYTE_STEP);
			return true;
		}
		case TAG_FLOAT32: {
			if (get_available_bytes() < 4) {
				return false;
			}
			float value;
			std::memcpy(&value, m_read + m_read_at, 4);
			m_read_at += 4;
			out = (double)value;
			return true;
		}
		case TAG_BOOL_FALSE:
			out = false;
			return true;
		case TAG_BOOL_TRUE:
			out = true;
			return true;
		case TAG_INT8: { // Claude 2026-11-07
			if (get_available_bytes() < 1) {
				return false;
			}
			out = (int64_t)(int8_t)m_read[m_read_at];
			m_read_at += 1;
			return true;
		}
		case TAG_INT16: { // Claude 2026-11-07
			if (get_available_bytes() < 2) {
				return false;
			}
			int16_t value;
			std::memcpy(&value, m_read + m_read_at, 2);
			m_read_at += 2;
			out = (int64_t)value;
			return true;
		}
		case TAG_INT32: {
			if (get_available_bytes() < 4) {
				return false;
			}
			int32_t value;
			std::memcpy(&value, m_read + m_read_at, 4);
			m_read_at += 4;
			out = (int64_t)value;
			return true;
		}
		case TAG_INT64: {
			if (get_available_bytes() < 8) {
				return false;
			}
			int64_t value;
			std::memcpy(&value, m_read + m_read_at, 8);
			m_read_at += 8;
			out = value;
			return true;
		}
		case TAG_OTHER: {
			if (get_available_bytes() < 4) {
				return false;
			}
			int32_t claimed;
			std::memcpy(&claimed, m_read + m_read_at, 4);
			if (claimed < 0 || get_available_bytes() < 4 + (int64_t)claimed) {
				return false;
			}
			m_read_at += 4;
			out = UtilityFunctions::bytes_to_var(m_read_bytes.slice(m_read_at, m_read_at + claimed));
			m_read_at += claimed;
			return true;
		}
		default:
			return false;
	}
}

bool NetCodec::read_list_into(Array &out) {
	if (get_available_bytes() < 1) {
		return false;
	}
	const int64_t count = m_read[m_read_at];
	m_read_at += 1;
	out.resize(count);
	for (int64_t i = 0; i < count; i++) {
		Variant value;
		if (!read_value(value)) {
			return false;
		}
		out[i] = value;
	}
	return true;
}

Variant NetCodec::read_list() {
	Array out;
	if (!read_list_into(out)) {
		return Variant();
	}
	return out;
}

Variant NetCodec::read_world(const PackedByteArray &bytes, int64_t start, int64_t count) {
	begin_read(bytes);
	// An entity takes at least 8 bytes, so a forged count can't ask for a huge list here.
	if (start < 0 || start > m_read_size || count < 0 || m_read_size - start < count * 8) {
		return Variant();
	}
	m_read_at = start;
	Array out;
	out.resize(count);
	for (int64_t i = 0; i < count; i++) {
		const int64_t id = read_u32();
		Array state, sync, input, custom;
		if (!read_list_into(state) || !read_list_into(sync) || !read_list_into(input) || !read_list_into(custom)) {
			return Variant();
		}
		Array item;
		item.resize(5);
		item[0] = id;
		item[1] = state;
		item[2] = sync;
		item[3] = input;
		item[4] = custom;
		out[i] = item;
	}
	return out;
}

void NetCodec::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_protocol_version"), &NetCodec::get_protocol_version);
	ClassDB::bind_method(D_METHOD("begin_write"), &NetCodec::begin_write);
	ClassDB::bind_method(D_METHOD("write_u32", "value"), &NetCodec::write_u32);
	ClassDB::bind_method(D_METHOD("write_list", "values", "encodings"), &NetCodec::write_list);
	ClassDB::bind_method(D_METHOD("write_world", "entries"), &NetCodec::write_world);
	ClassDB::bind_method(D_METHOD("get_written"), &NetCodec::get_written);
	ClassDB::bind_method(D_METHOD("begin_read", "bytes"), &NetCodec::begin_read);
	ClassDB::bind_method(D_METHOD("get_available_bytes"), &NetCodec::get_available_bytes);
	ClassDB::bind_method(D_METHOD("read_u32"), &NetCodec::read_u32);
	ClassDB::bind_method(D_METHOD("read_list"), &NetCodec::read_list);
	ClassDB::bind_method(D_METHOD("read_world", "bytes", "start", "count"), &NetCodec::read_world);
}
