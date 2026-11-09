// Written by Claude (claude-opus-5-5), 2026-11-09: see ai_memory_store.h. Every rule here mirrors AIMemoryStoreGD.gd and
// SightSense.gd; a change to one goes in the other, and ai_perception_selftest runs both.
#include "ai_memory_store.h"
#include "ai_sensing_job.h" // Claude 2026-11-09 (scaling spec step 2)

#include <godot_cpp/classes/collision_object3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace {
// Claude 2026-11-09, step 10: dead pawns aren't seen, and are forgotten. Pawn.is_dead() in GDScript.
bool is_dead(Object *entity) {
	return entity != nullptr && entity->has_method("is_dead") && bool(entity->call("is_dead"));
}

// FadeProfile.HALVINGS_UNTIL_NOTHING: 0.5^7 is about 0.8%, the first step below 1%.
constexpr int64_t HALVINGS_UNTIL_NOTHING = 7;
constexpr double EPSILON = 0.000001;

Object *instance_of(uint64_t id) {
	return ObjectDB::get_instance(id);
}
} // namespace

AIMemoryStore::AIMemoryStore() {
	_ray.instantiate();
}

// --- Fades ---

void AIMemoryStore::read_fade(Fade &into, const Ref<Resource> &profile, int64_t delay, bool custom) {
	into = Fade();
	into.delay = delay;
	into.profile = profile;
	if (profile.is_null()) {
		return;
	}
	if (custom) {
		into.custom = profile;
		return;
	}
	into.mode = int(profile->get("mode"));
	into.hold = int64_t(profile->get("hold_ticks"));
	into.fade = int64_t(profile->get("fade_ticks"));
	into.half_life = int64_t(profile->get("half_life_ticks"));
	into.curve = profile->get("curve");
}

int64_t AIMemoryStore::ends_after(const Fade &fade) {
	if (fade.custom.is_valid()) {
		return int64_t(fade.custom->call("ends_after"));
	}
	if (fade.mode == 1) {
		return fade.hold + fade.half_life * HALVINGS_UNTIL_NOTHING;
	}
	return fade.hold + fade.fade;
}

double AIMemoryStore::value_at(const Fade &fade, double ticks) {
	if (fade.custom.is_valid()) {
		return double(fade.custom->call("value_at", ticks));
	}
	if (fade.profile.is_null()) {
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

void AIMemoryStore::configure_fades(const Ref<Resource> &uncertain, int64_t uncertain_delay, bool uncertain_custom,
		const Ref<Resource> &certain, int64_t certain_delay, bool certain_custom, int64_t continuous_sighting_ticks) {
	read_fade(_uncertain, uncertain, uncertain_delay, uncertain_custom);
	read_fade(_certain_fade, certain, certain_delay, certain_custom);
	_continuous_ticks = continuous_sighting_ticks;
}

// --- Entries ---

double AIMemoryStore::awareness_of(size_t i, int64_t tick) const {
	const Fade &fade = _certain[i] ? _certain_fade : _uncertain;
	return _awareness_when_seen[i] * value_at(fade, double(tick - _last_seen[i] - fade.delay));
}

int64_t AIMemoryStore::entry_count() const {
	return int64_t(_ids.size());
}

int64_t AIMemoryStore::find(Object *entity) const {
	if (entity == nullptr) {
		return -1;
	}
	auto found = _index_of.find(entity->get_instance_id());
	return found == _index_of.end() ? -1 : int64_t(found->second);
}

Object *AIMemoryStore::entity_at(int64_t index) const {
	return instance_of(_ids[size_t(index)]);
}

double AIMemoryStore::awareness_at(int64_t index, int64_t tick) const {
	return awareness_of(size_t(index), tick);
}

bool AIMemoryStore::is_certain_at(int64_t index) const {
	return _certain[size_t(index)] != 0;
}

Vector3 AIMemoryStore::last_known_position_at(int64_t index) const {
	return _last_known[size_t(index)];
}

int64_t AIMemoryStore::ticks_since_seen_at(int64_t index, int64_t tick) const {
	return tick - _last_seen[size_t(index)];
}

double AIMemoryStore::threat_at(int64_t index) const {
	return _threat[size_t(index)];
}

int64_t AIMemoryStore::ticks_since_checked(Object *entity, int64_t tick, int64_t fallback) const {
	const int64_t i = find(entity);
	return i < 0 ? fallback : tick - _last_checked[size_t(i)];
}

int64_t AIMemoryStore::record_sighting(Object *entity, double gain, int64_t tick, const Vector3 &position) {
	int64_t result = 0;
	int64_t found = find(entity);
	size_t i;
	if (found < 0) {
		i = _ids.size();
		_ids.push_back(entity->get_instance_id());
		_last_known.push_back(position);
		_last_seen.push_back(tick);
		_last_checked.push_back(tick);
		_awareness_when_seen.push_back(0.0);
		_certain.push_back(0);
		_threat.push_back(0.0);
		_index_of[_ids[i]] = i;
		result |= 1;
	} else {
		i = size_t(found);
	}
	// Fading only counts while it isn't seen: sightings close together, with no unseen check between them, are one look.
	const bool in_view_all_along = _last_checked[i] == _last_seen[i] && tick - _last_seen[i] <= _continuous_ticks;
	const double before = in_view_all_along ? _awareness_when_seen[i] : awareness_of(i, tick);
	const double now = _certain[i] ? 1.0 : std::min(1.0, before + gain);
	_last_known[i] = position;
	_last_seen[i] = tick;
	_last_checked[i] = tick;
	_awareness_when_seen[i] = now;
	if (now >= 1.0 && !_certain[i]) {
		_certain[i] = 1;
		result |= 2;
	}
	return result;
}

void AIMemoryStore::record_check(Object *entity, int64_t tick) {
	const int64_t i = find(entity);
	if (i >= 0) {
		_last_checked[size_t(i)] = tick;
	}
}

void AIMemoryStore::add_threat(Object *entity, double amount) {
	const int64_t i = find(entity);
	if (i >= 0) {
		_threat[size_t(i)] = std::max(0.0, _threat[size_t(i)] + amount);
	}
}

void AIMemoryStore::remove(size_t i) {
	_index_of.erase(_ids[i]);
	for (size_t later = i + 1; later < _ids.size(); ++later) {
		_index_of[_ids[later]] = later - 1;
	}
	_ids.erase(_ids.begin() + i);
	_last_known.erase(_last_known.begin() + i);
	_last_seen.erase(_last_seen.begin() + i);
	_last_checked.erase(_last_checked.begin() + i);
	_awareness_when_seen.erase(_awareness_when_seen.begin() + i);
	_certain.erase(_certain.begin() + i);
	_threat.erase(_threat.begin() + i);
}

PackedInt64Array AIMemoryStore::forget_old(int64_t tick) {
	PackedInt64Array forgotten;
	for (int64_t i = int64_t(_ids.size()) - 1; i >= 0; --i) { // backwards, so removing one doesn't move the ones still to check
		const Fade &fade = _certain[size_t(i)] ? _certain_fade : _uncertain;
		Object *entity = instance_of(_ids[size_t(i)]);
		if (entity == nullptr || is_dead(entity) || tick - _last_seen[size_t(i)] >= fade.delay + ends_after(fade)) {
			if (entity != nullptr) {
				forgotten.push_back(int64_t(_ids[size_t(i)]));
			}
			remove(size_t(i));
		}
	}
	return forgotten;
}

int64_t AIMemoryStore::most_aware_index(const Vector3 &from, int64_t tick) const {
	int64_t best = -1;
	double best_awareness = -1.0;
	double best_distance = std::numeric_limits<double>::infinity();
	for (size_t i = 0; i < _ids.size(); ++i) {
		const double awareness = awareness_of(i, tick);
		const double distance = from.distance_squared_to(_last_known[i]);
		if (awareness > best_awareness + EPSILON ||
				(std::abs(awareness - best_awareness) <= EPSILON &&
						(distance < best_distance || (distance == best_distance && _ids[i] < _ids[size_t(best)])))) {
			best = int64_t(i);
			best_awareness = awareness;
			best_distance = distance;
		}
	}
	return best;
}

void AIMemoryStore::clear() {
	_ids.clear();
	_last_known.clear();
	_last_seen.clear();
	_last_checked.clear();
	_awareness_when_seen.clear();
	_certain.clear();
	_threat.clear();
	_index_of.clear();
}

// --- Target scoring ---

int64_t AIMemoryStore::best_target(const Vector3 &from, double awareness_weight, double distance_weight, double threat_weight,
		double distance_range, double min_awareness, int64_t current_id, double current_bonus, int64_t tick) const {
	int64_t best = -1;
	double best_priority = -std::numeric_limits<double>::infinity();
	double best_distance = std::numeric_limits<double>::infinity();
	uint64_t best_id = 0;
	for (size_t i = 0; i < _ids.size(); ++i) {
		const double awareness = awareness_of(i, tick);
		if (awareness < min_awareness || instance_of(_ids[i]) == nullptr) {
			continue;
		}
		const double distance = from.distance_to(_last_known[i]);
		double priority = awareness_weight * awareness +
				distance_weight * (1.0 - std::clamp(distance / distance_range, 0.0, 1.0)) +
				threat_weight * _threat[i];
		if (current_id != 0 && _ids[i] == uint64_t(current_id)) {
			priority += current_bonus;
		}
		const double distance_squared = distance * distance;
		if (priority > best_priority + EPSILON ||
				(std::abs(priority - best_priority) <= EPSILON &&
						(distance_squared < best_distance || (distance_squared == best_distance && _ids[i] < best_id)))) {
			best = int64_t(i);
			best_priority = priority;
			best_distance = distance_squared;
			best_id = _ids[i];
		}
	}
	return best;
}

// --- Sight ---

void AIMemoryStore::set_sight_settings(const PackedFloat64Array &s) {
	_sight.read(s); // Claude 2026-11-09 (step 2): the shared struct; fewer than 11 numbers change nothing, as before
}

// Claude 2026-11-09 (scaling spec step 2): the visibility rule moved to ai_sight_rules.h and the ray and record to check_one, so that
// sight_check_prepared does exactly the same with the job's numbers.
Array AIMemoryStore::sight_check(Object *observer_object, double eye_yaw, const Array &candidates, int64_t tick) {
	Array became_certain;
	bool added = false;
	Node3D *observer = Object::cast_to<Node3D>(observer_object);
	if (observer == nullptr || !observer->is_inside_tree()) {
		Array result;
		result.push_back(false);
		result.push_back(became_certain);
		return result;
	}
	const Vector3 eye = observer->get_global_position() + Vector3(0.0, _sight.eye_height, 0.0);
	const Vector2 facing = sight_rules::facing_from_yaw(eye_yaw);
	PhysicsDirectSpaceState3D *space = nullptr;

	const int64_t count = candidates.size();
	for (int64_t c = 0; c < count; ++c) {
		Node3D *target = Object::cast_to<Node3D>(candidates[c].operator Object *());
		if (target == nullptr || target == observer || !target->is_inside_tree() || is_dead(target)) {
			continue;
		}
		const Vector3 target_position = target->get_global_position();
		const Vector3 aim = target_position + Vector3(0.0, _sight.target_height, 0.0);
		// Visibility: distance × angle × detectability, as SightSense.visibility_of.
		const double visibility = sight_rules::visibility(_sight, eye, facing, aim, double(target->get("detectability")));
		check_one(observer, target, eye, aim, target_position, visibility, tick, space, added, became_certain);
	}
	Array result;
	result.push_back(added);
	result.push_back(became_certain);
	return result;
}

Array AIMemoryStore::sight_check_prepared(Object *job_object, Object *observer_object, int64_t tick) {
	Array became_certain;
	bool added = false;
	Array result;
	AISensingJob *job = Object::cast_to<AISensingJob>(job_object);
	Node3D *observer = Object::cast_to<Node3D>(observer_object);
	int64_t count = 0;
	Vector3 eye;
	const AISensingJob::Candidate *candidates = (job && observer && observer->is_inside_tree()) ? job->take(observer, tick, count, eye) : nullptr;
	if (candidates == nullptr) {
		result.push_back(false);
		result.push_back(became_certain);
		return result;
	}
	PhysicsDirectSpaceState3D *space = nullptr;
	for (int64_t c = 0; c < count; ++c) {
		const AISensingJob::Candidate &candidate = candidates[c];
		// The same checks sight_check makes before visibility: the job only knew the table, not whether a pawn has died or left.
		Node3D *target = Object::cast_to<Node3D>(instance_of(candidate.id));
		if (target == nullptr || target == observer || !target->is_inside_tree() || is_dead(target)) {
			continue;
		}
		check_one(observer, target, eye, candidate.aim, candidate.position, candidate.visibility, tick, space, added, became_certain);
	}
	result.push_back(added);
	result.push_back(became_certain);
	return result;
}

void AIMemoryStore::check_one(Node3D *observer, Node3D *target, const Vector3 &eye, const Vector3 &aim, const Vector3 &target_position,
		double visibility, int64_t tick, PhysicsDirectSpaceState3D *&space, bool &added, Array &became_certain) {
	const int64_t ticks = std::clamp(ticks_since_checked(target, tick, _sight.sense_interval), int64_t(0), _sight.max_gain_ticks);
	bool seen = false;
	// The ray is the expensive part, so it's only cast when the target could be seen at all.
	if (visibility > 0.0 && ticks > 0) {
		if (space == nullptr) {
			space = observer->get_world_3d()->get_direct_space_state();
		}
		_ray->set_from(eye);
		_ray->set_to(aim);
		_ray->set_collision_mask(_sight.blocking_mask);
		CollisionObject3D *observer_body = Object::cast_to<CollisionObject3D>(observer);
		CollisionObject3D *target_body = Object::cast_to<CollisionObject3D>(target);
		const uint32_t layers = (observer_body ? observer_body->get_collision_layer() : 0) | (target_body ? target_body->get_collision_layer() : 0);
		TypedArray<RID> exclude;
		if (_sight.blocking_mask & layers) {
			if (observer_body) {
				exclude.push_back(observer_body->get_rid());
			}
			if (target_body) {
				exclude.push_back(target_body->get_rid());
			}
		}
		_ray->set_exclude(exclude);
		seen = space != nullptr && space->intersect_ray(_ray).is_empty();
	}
	if (seen) {
		const int64_t bits = record_sighting(target, _sight.fill_rate * double(ticks) * visibility, tick, target_position);
		added = added || (bits & 1);
		if (bits & 2) {
			became_certain.push_back(target);
		}
	} else {
		record_check(target, tick);
	}
}

// --- Binding ---

void AIMemoryStore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure_fades", "uncertain", "uncertain_delay", "uncertain_custom", "certain", "certain_delay",
								 "certain_custom", "continuous_sighting_ticks"),
			&AIMemoryStore::configure_fades);
	ClassDB::bind_method(D_METHOD("entry_count"), &AIMemoryStore::entry_count);
	ClassDB::bind_method(D_METHOD("find", "entity"), &AIMemoryStore::find);
	ClassDB::bind_method(D_METHOD("entity_at", "index"), &AIMemoryStore::entity_at);
	ClassDB::bind_method(D_METHOD("awareness_at", "index", "tick"), &AIMemoryStore::awareness_at);
	ClassDB::bind_method(D_METHOD("is_certain_at", "index"), &AIMemoryStore::is_certain_at);
	ClassDB::bind_method(D_METHOD("last_known_position_at", "index"), &AIMemoryStore::last_known_position_at);
	ClassDB::bind_method(D_METHOD("ticks_since_seen_at", "index", "tick"), &AIMemoryStore::ticks_since_seen_at);
	ClassDB::bind_method(D_METHOD("threat_at", "index"), &AIMemoryStore::threat_at);
	ClassDB::bind_method(D_METHOD("ticks_since_checked", "entity", "tick", "fallback"), &AIMemoryStore::ticks_since_checked);
	ClassDB::bind_method(D_METHOD("record_sighting", "entity", "gain", "tick", "position"), &AIMemoryStore::record_sighting);
	ClassDB::bind_method(D_METHOD("record_check", "entity", "tick"), &AIMemoryStore::record_check);
	ClassDB::bind_method(D_METHOD("add_threat", "entity", "amount"), &AIMemoryStore::add_threat);
	ClassDB::bind_method(D_METHOD("forget_old", "tick"), &AIMemoryStore::forget_old);
	ClassDB::bind_method(D_METHOD("most_aware_index", "from", "tick"), &AIMemoryStore::most_aware_index);
	ClassDB::bind_method(D_METHOD("clear"), &AIMemoryStore::clear);
	ClassDB::bind_method(D_METHOD("best_target", "from", "awareness_weight", "distance_weight", "threat_weight", "distance_range",
								 "min_awareness", "current_id", "current_bonus", "tick"),
			&AIMemoryStore::best_target);
	ClassDB::bind_method(D_METHOD("set_sight_settings", "settings"), &AIMemoryStore::set_sight_settings);
	ClassDB::bind_method(D_METHOD("sight_check", "observer", "eye_yaw", "candidates", "tick"), &AIMemoryStore::sight_check);
	ClassDB::bind_method(D_METHOD("sight_check_prepared", "job", "observer", "tick"), &AIMemoryStore::sight_check_prepared); // Claude 2026-11-09
}
