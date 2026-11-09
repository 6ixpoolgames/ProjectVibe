// Written by Claude (claude-opus-5-5), 2026-11-09: one pawn's AI memory in C++, plus the loops that read and write it: the sight
// check, the most aware entry and target scoring. Pawn spec sections 10.4, 10.5 and 10.11.
//
// AIMemory.gd owns one of these and keeps every setting: the fades, their delays, the sight settings and the target weights all stay
// exported on the GDScript nodes and are passed in here, so designers tune the same inspector values whichever version runs.
// assets/scripts/ai/AIMemoryStoreGD.gd is the same thing in GDScript, used where this library isn't available, and the tests run
// both and expect the same results.
//
// Why it exists: in ai_stress (200 pawns, each with 32 enemies in sight) sensing and target selection were about 5.6 ms a tick in
// GDScript, mostly many small steps per entry. Here they're plain loops over arrays.
//
// Fades: a FadeProfile's settings (mode, hold, fade, half-life, curve) are read once when it's configured, and the maths is done
// here. A profile whose script overrides value_at() (a "custom" profile) is called instead, so a designer's own fade still works.
#pragma once

#include "ai_sight_rules.h"
#include "sight_geometry.h" // Claude 2026-11-09 (scaling spec step 4): line of sight in C++ // Claude 2026-11-09 (scaling spec step 2): the visibility rule, shared with AISensingJob

#include <godot_cpp/classes/curve.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class Node3D;
class PhysicsDirectSpaceState3D;

class AIMemoryStore : public RefCounted {
	GDCLASS(AIMemoryStore, RefCounted)

public:
	AIMemoryStore();

	// Fades. profile is a FadeProfile; custom is true when its script overrides value_at(), and then it's called instead.
	void configure_fades(const Ref<Resource> &uncertain, int64_t uncertain_delay, bool uncertain_custom,
			const Ref<Resource> &certain, int64_t certain_delay, bool certain_custom, int64_t continuous_sighting_ticks);

	int64_t entry_count() const;
	int64_t find(Object *entity) const;
	Object *entity_at(int64_t index) const;
	double awareness_at(int64_t index, int64_t tick) const;
	bool is_certain_at(int64_t index) const;
	Vector3 last_known_position_at(int64_t index) const;
	int64_t ticks_since_seen_at(int64_t index, int64_t tick) const;
	double threat_at(int64_t index) const;
	int64_t ticks_since_checked(Object *entity, int64_t tick, int64_t fallback) const;
	// Returns bits: 1 when a new entry was made, 2 when the entry became certain.
	int64_t record_sighting(Object *entity, double gain, int64_t tick, const Vector3 &position);
	void record_check(Object *entity, int64_t tick);
	void add_threat(Object *entity, double amount);
	// Forgets entries whose fade has ended or whose entity is gone. Returns the ids of forgotten entities that still exist.
	PackedInt64Array forget_old(int64_t tick);
	int64_t most_aware_index(const Vector3 &from, int64_t tick) const;
	void clear();

	// Target scoring (AITargetSelector's formula). current_id is the current target's instance id (0: none), and current_bonus the
	// bonus it gets now. Returns the winning index, or -1.
	int64_t best_target(const Vector3 &from, double awareness_weight, double distance_weight, double threat_weight,
			double distance_range, double min_awareness, int64_t current_id, double current_bonus, int64_t tick) const;

	// Sight (SightSense's settings, in this order): fill_rate, near_range, sight_range, cos of half the central cone, cos of half the
	// periphery, periphery_multiplier, max_gain_ticks, eye_height, target_height, sight_blocking_mask, sense_interval_ticks.
	void set_sight_settings(const PackedFloat64Array &settings);
	// Checks each candidate (Pawns) from observer's eyes, facing eye_yaw, and records what's seen. Returns
	// [a new entry was made (bool), entities that became certain (Array)].
	Array sight_check(Object *observer, double eye_yaw, const Array &candidates, int64_t tick);
	// Claude 2026-11-09 (scaling spec step 2): the same check, with the candidates and their visibility already found by an
	// AISensingJob for this observer and tick (job is the AISensingJob). Casts the rays and records, exactly as sight_check does with
	// the same candidates. Returns the same as sight_check; nothing happens if the job has no result for this observer and tick.
	Array sight_check_prepared(Object *job, Object *observer, int64_t tick);
	// Claude 2026-11-09 (scaling spec step 4): where line of sight is tested instead of physics rays: the shared SightGeometry, or
	// null for physics rays. Physics rays are still used for a check whose mask includes the observer's or the target's own layer,
	// because pawns aren't in the geometry.
	void set_sight_geometry(const Ref<SightGeometry> &geometry);

protected:
	static void _bind_methods();

private:
	struct Fade {
		int mode = 0; // 0 LINEAR, 1 HALF_LIFE, 2 CURVE (the order of FadeProfile.Mode)
		int64_t hold = 0;
		int64_t fade = 60;
		int64_t half_life = 30;
		int64_t delay = 0;
		Ref<Curve> curve;
		Ref<Resource> custom; // set when the profile's own value_at() must be called
		Ref<Resource> profile;
	};

	static void read_fade(Fade &into, const Ref<Resource> &profile, int64_t delay, bool custom);
	static double value_at(const Fade &fade, double ticks);
	static int64_t ends_after(const Fade &fade);
	double awareness_of(size_t i, int64_t tick) const;
	bool in_view(size_t i, int64_t tick) const; // Claude 2026-11-09: held, not fading: the last check saw it, recently
	// Claude 2026-11-09 (step 2): one candidate's check once its visibility is known: the ray if it could be seen, then the record.
	// Both sight checks use it, so they record the same things in the same order.
	// Claude 2026-11-09 (step 4): ray is what's already known about line of sight: -1 nothing (test it now), 0 clear, 1 blocked.
	void check_one(Node3D *observer, Node3D *target, const Vector3 &eye, const Vector3 &aim, const Vector3 &target_position,
			double visibility, int64_t tick, int ray, PhysicsDirectSpaceState3D *&space, bool &added, Array &became_certain);
	void remove(size_t i);

	std::vector<uint64_t> _ids;
	std::vector<Vector3> _last_known;
	std::vector<int64_t> _last_seen;
	std::vector<int64_t> _last_checked;
	std::vector<double> _awareness_when_seen;
	std::vector<uint8_t> _certain;
	std::vector<double> _threat;
	std::unordered_map<uint64_t, size_t> _index_of;

	Fade _uncertain;
	Fade _certain_fade;
	int64_t _continuous_ticks = 30;

	// Claude 2026-11-09 (scaling spec step 2): SightSense's settings, in the struct the sensing job shares (ai_sight_rules.h).
	sight_rules::Settings _sight;
	Ref<SightGeometry> _geometry; // Claude 2026-11-09 (step 4)
	Ref<PhysicsRayQueryParameters3D> _ray;
};

} // namespace godot
