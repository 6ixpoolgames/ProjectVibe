// Written by Claude (claude-opus-5-5), 2026-11-09: how strongly one pawn sees another, before line of sight and time: distance ×
// angle × detectability (SightSense.gd's visibility_of, pawn spec 10.4). One copy of the rule, used by AIMemoryStore's sight check on
// the main thread and by AISensingJob on worker threads (scaling spec step 2), so the two can't drift apart and give exactly the same
// numbers. Plain maths only: safe on any thread.
#pragma once

#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace godot {
namespace sight_rules {

// SightSense's settings, in the order SightSense packs them (AIMemoryStore.set_sight_settings): fill_rate, near_range, sight_range,
// cos of half the central cone, cos of half the periphery, periphery_multiplier, max_gain_ticks, eye_height, target_height,
// sight_blocking_mask, sense_interval_ticks.
struct Settings {
	double fill_rate = 1.0 / 30.0;
	double near_range = 8.0;
	double sight_range = 25.0;
	double cos_central = 0.7071;
	double cos_periphery = 0.1736;
	double periphery_multiplier = 0.3;
	int64_t max_gain_ticks = 30;
	double eye_height = 1.6;
	double target_height = 1.0;
	uint32_t blocking_mask = 1;
	int64_t sense_interval = 10;

	// False (and nothing changes) when there are fewer than 11 numbers.
	bool read(const PackedFloat64Array &s) {
		if (s.size() < 11) {
			return false;
		}
		fill_rate = s[0];
		near_range = s[1];
		sight_range = s[2];
		cos_central = s[3];
		cos_periphery = s[4];
		periphery_multiplier = s[5];
		max_gain_ticks = int64_t(s[6]);
		eye_height = s[7];
		target_height = s[8];
		blocking_mask = uint32_t(int64_t(s[9]));
		sense_interval = int64_t(s[10]);
		return true;
	}
};

// Which way the eyes face, flat: Godot's forward is -Z, so yaw 0 faces -Z.
inline Vector2 facing_from_yaw(double eye_yaw) {
	return Vector2(-std::sin(eye_yaw), -std::cos(eye_yaw));
}

// distance_factor × angle_factor × detectability, or 0 when out of range or outside the periphery. eye is where the observer's eyes
// are, aim the point on the target the ray would aim at.
inline double visibility(const Settings &s, const Vector3 &eye, const Vector2 &facing, const Vector3 &aim, double detectability) {
	const double distance = eye.distance_to(aim);
	if (distance > s.sight_range) {
		return 0.0;
	}
	double distance_factor = 1.0;
	if (distance > s.near_range) {
		distance_factor = 1.0 - (distance - s.near_range) / std::max(s.sight_range - s.near_range, 0.001);
	}
	double angle_factor = 1.0;
	const Vector2 flat(aim.x - eye.x, aim.z - eye.z);
	if (flat.length_squared() > 0.0001) {
		const double cosine = facing.dot(flat.normalized());
		if (cosine < s.cos_periphery) {
			return 0.0;
		}
		if (cosine < s.cos_central) {
			angle_factor = s.periphery_multiplier;
		}
	}
	return distance_factor * angle_factor * detectability;
}

} // namespace sight_rules
} // namespace godot
