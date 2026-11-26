// Written by Claude (claude-opus-5-5), 2026-11-18. History: native/CHANGELOG.md.
// fade_math: FadeProfile's maths (assets/scripts/ai/FadeProfile.gd) in C++, in one place. AIMemoryStore uses it for memory's fades
// (the AI decider used it for behaviours' persistence, which is gone).
//
// A profile's settings are read once (read()), at the match's tick rate, and the maths is done here. A drawn curve is read with
// Curve::sample_baked, a table Godot works out once and keeps, so a curve is "sampled once and referenced" as the owner asked. A
// profile whose script overrides value_at() (a "custom" one) is called instead, so a designer's own fade still works; it calls into
// GDScript, so the decider treats a pawn with one as a special mind that decides in GDScript.
#pragma once

#include <godot_cpp/classes/curve.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/resource.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace godot {
namespace fade_math {

// FadeProfile.HALVINGS_UNTIL_NOTHING: 0.5^7 is about 0.8%, the first step below 1%.
constexpr int64_t HALVINGS_UNTIL_NOTHING = 7;

// One profile's settings, at the match's tick rate. No profile: always full (1.0).
struct Fade {
	int mode = 0; // 0 LINEAR, 1 HALF_LIFE, 2 CURVE (the order of FadeProfile.Mode)
	int64_t hold = 0;
	int64_t fade = 60;
	int64_t half_life = 30;
	int64_t delay = 0; // memory's own delay before a fade starts; persistence has none
	Ref<Curve> curve;
	Ref<Resource> custom; // set when the profile's own value_at() must be called
	Ref<Resource> profile;
	bool has_profile = false; // false: no profile, so always full
};

// round(ticks × rate ÷ 60), at least 1 above 0, as TickDriver.ticks_at_rate.
inline int64_t at_rate(int64_t reference_ticks, int64_t rate) {
	if (reference_ticks <= 0 || rate == 60) {
		return reference_ticks;
	}
	return std::max<int64_t>(1, std::llround(double(reference_ticks) * double(rate) / 60.0));
}

// Reads a FadeProfile (null: none) at this tick rate. custom: its script overrides value_at().
inline void read(Fade &into, const Ref<Resource> &profile, int64_t delay, bool custom, int64_t rate) {
	into = Fade();
	into.delay = delay;
	into.profile = profile;
	if (profile.is_null()) {
		return;
	}
	into.has_profile = true;
	if (custom) {
		into.custom = profile;
		return;
	}
	into.mode = int(profile->get("mode"));
	into.hold = at_rate(int64_t(profile->get("hold_ticks")), rate);
	into.fade = at_rate(int64_t(profile->get("fade_ticks")), rate);
	into.half_life = at_rate(int64_t(profile->get("half_life_ticks")), rate);
	into.curve = profile->get("curve");
}

// The same from values already at the match's rate (AIBehaviourManager.describe() sends them so).
inline void read_values(Fade &into, int mode, int64_t hold, int64_t fade, int64_t half_life, const Ref<Curve> &curve) {
	into = Fade();
	into.mode = mode;
	into.hold = hold;
	into.fade = fade;
	into.half_life = half_life;
	into.curve = curve;
	into.has_profile = true;
}

// FadeProfile.ends_after(): ticks until it's nothing.
inline int64_t ends_after(const Fade &fade) {
	if (fade.custom.is_valid()) {
		return int64_t(fade.custom->call("ends_after"));
	}
	if (fade.mode == 1) {
		return fade.hold + fade.half_life * HALVINGS_UNTIL_NOTHING;
	}
	return fade.hold + fade.fade;
}

// FadeProfile.value_at(): 1.0 during the hold, then the fade down to 0.0, with the same arithmetic.
inline double value_at(const Fade &fade, double ticks) {
	if (fade.custom.is_valid()) {
		return double(fade.custom->call("value_at", ticks));
	}
	if (!fade.has_profile) {
		return 1.0;
	}
	if (ticks < double(fade.hold)) {
		return 1.0;
	}
	if (ticks >= double(ends_after(fade))) {
		return 0.0;
	}
	const double into_fade = ticks - double(fade.hold);
	if (fade.mode == 1) {
		return std::pow(0.5, into_fade / double(fade.half_life));
	}
	if (fade.mode == 2 && fade.curve.is_valid()) {
		return std::clamp(double(fade.curve->sample_baked(float(into_fade / double(fade.fade)))), 0.0, 1.0);
	}
	return 1.0 - into_fade / double(fade.fade);
}

} // namespace fade_math
} // namespace godot
