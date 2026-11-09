// Written by Claude (claude-opus-5-5), 2026-11-09: see ai_sensing_job.h.
#include "ai_sensing_job.h"

#include <godot_cpp/classes/collision_object3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>

using namespace godot;

AISensingJob::~AISensingJob() {
	if (_handle != 0 && _scheduler.is_valid()) {
		_scheduler->finish(_handle);
	}
}

void AISensingJob::setup(const Ref<JobScheduler> &scheduler, const Ref<AIPawnGrid> &grid) {
	if (_handle != 0 && _scheduler.is_valid()) {
		_scheduler->finish(_handle);
	}
	_scheduler = scheduler;
	_grid = grid;
	_handle = 0;
	_pending.clear();
	_requests.clear();
	_request_of.clear();
	_due_tick = -1;
	if (_scheduler.is_null() || _grid.is_null() || _grid->get_table().is_null()) {
		return;
	}
	// A first guess of 20 µs per pawn (a grid query of about 18 µs in ai_stress, plus the sums); measured from the first run on.
	_kind = _scheduler->kind("sensing", 20.0);
	Ref<PawnTable> table = _grid->get_table();
	table->require_column("detectability"); // the automatic switch: this job reads it
	_detectability = table->column_index("detectability");
	// The table never changes while a job reads it: anything that would change it finishes the running jobs first.
	Ref<JobScheduler> held = _scheduler;
	table->set_change_guard([held]() { held->finish_all(); });
}

void AISensingJob::set_geometry(const Ref<SightGeometry> &geometry) {
	if (_handle != 0 && _scheduler.is_valid()) {
		_scheduler->finish(_handle);
	}
	_geometry = geometry;
	if (_geometry.is_valid() && _scheduler.is_valid()) {
		Ref<JobScheduler> held = _scheduler;
		_geometry->set_change_guard([held]() { held->finish_all(); });
	}
}

bool AISensingJob::add_request(Object *observer_object, double eye_yaw, double reach, int64_t max_candidates, const PackedFloat64Array &sight_settings) {
	Node3D *observer = Object::cast_to<Node3D>(observer_object);
	if (_scheduler.is_null() || observer == nullptr || !observer->is_inside_tree()) {
		return false;
	}
	Request r;
	if (!r.sight.read(sight_settings)) {
		UtilityFunctions::push_error("AISensingJob.add_request: sight_settings needs 11 numbers, in AIMemoryStore.set_sight_settings' order.");
		return false;
	}
	r.observer = observer->get_instance_id();
	// Worked out exactly as AIMemoryStore.sight_check works it out, so the numbers are the same.
	r.eye = observer->get_global_position() + Vector3(0.0, r.sight.eye_height, 0.0);
	r.eye_yaw = eye_yaw;
	r.reach = reach;
	r.max_candidates = std::max<int64_t>(max_candidates, 0);
	// Claude 2026-11-09 (step 4): as AIMemoryStore.check_one decides it, for the observer's side; the target's side is checked when
	// the result is used.
	CollisionObject3D *body = Object::cast_to<CollisionObject3D>(observer);
	r.use_geometry = _geometry.is_valid() && (r.sight.blocking_mask & (body ? body->get_collision_layer() : 0)) == 0;
	_pending.push_back(r);
	return true;
}

void AISensingJob::start(int64_t tick) {
	if (_scheduler.is_null()) {
		return;
	}
	if (_handle != 0) {
		_scheduler->finish(_handle); // the old buffers can't go while workers might still write them
		_handle = 0;
	}
	_requests.swap(_pending);
	_pending.clear();
	_request_of.clear();
	_candidates.clear();
	_due_tick = tick + 1;
	if (_requests.empty()) {
		return;
	}
	// Read the table now, at the end of tick T, even if it was read earlier this tick: the job must see where this tick left every
	// pawn. Then the grid, from it. Both on the main thread, before any worker starts.
	Ref<PawnTable> table = _grid->get_table();
	table->mark_stale();
	_grid->prepare(tick);
	_table = table.ptr(); // for the workers, which mustn't touch Godot's reference counts
	if (_geometry.is_valid()) {
		_geometry->sync(tick); // Claude 2026-11-09 (step 4): on the main thread, before the workers read it
	}
	size_t places = 0;
	for (size_t i = 0; i < _requests.size(); ++i) {
		Request &r = _requests[i];
		r.slot = table->get_slot(ObjectDB::get_instance(r.observer));
		r.team = r.slot >= 0 ? table->team_at(r.slot) : 0;
		r.first = places;
		r.found = 0;
		places += size_t(r.max_candidates);
		_request_of[r.observer] = i;
	}
	_candidates.resize(places);
	_total_requests += int64_t(_requests.size());
	_handle = _scheduler->start(_kind, int32_t(_requests.size()), [this](int32_t begin, int32_t end) { run_requests(begin, end); });
}

// On any thread: reads only the table and the grid, which don't change while this runs, and writes only these requests' places.
void AISensingJob::run_requests(int32_t begin, int32_t end) {
	const PawnTable *table = _table;
	std::vector<std::pair<double, uint32_t>> found; // this batch's own scratch
	for (int32_t i = begin; i < end; ++i) {
		Request &r = _requests[size_t(i)];
		if (r.slot < 0) {
			continue;
		}
		const size_t keep = _grid->find_slots(table->position_at(r.slot), r.reach, r.team, r.slot, size_t(r.max_candidates), found);
		const Vector2 facing = sight_rules::facing_from_yaw(r.eye_yaw);
		for (size_t c = 0; c < keep; ++c) {
			const uint32_t slot = found[c].second;
			Candidate &out = _candidates[r.first + c];
			out.id = table->id_at(slot);
			out.position = table->position_at(slot);
			out.aim = out.position + Vector3(0.0, r.sight.target_height, 0.0);
			const double detectability = _detectability >= 0 ? table->numbers(_detectability)[slot] : 1.0;
			out.visibility = sight_rules::visibility(r.sight, r.eye, facing, out.aim, detectability);
			// Claude 2026-11-09 (step 4): the ray too, when it could matter.
			out.ray = (r.use_geometry && out.visibility > 0.0) ? (_geometry->blocked(r.eye, out.aim, r.sight.blocking_mask) ? 1 : 0) : -1;
		}
		r.found = int64_t(keep);
	}
}

int64_t AISensingJob::find_request(Object *observer, int64_t tick) const {
	if (observer == nullptr || tick != _due_tick) {
		return -1;
	}
	auto found = _request_of.find(observer->get_instance_id());
	return found == _request_of.end() ? -1 : int64_t(found->second);
}

bool AISensingJob::has_result(Object *observer, int64_t tick) const {
	return find_request(observer, tick) >= 0;
}

const AISensingJob::Candidate *AISensingJob::take(Object *observer, int64_t tick, int64_t &count, Vector3 &eye) {
	count = 0;
	const int64_t i = find_request(observer, tick);
	if (i < 0) {
		return nullptr;
	}
	if (_handle != 0) {
		_scheduler->finish(_handle); // usually already done: the workers had the time between ticks
	}
	const Request &r = _requests[size_t(i)];
	count = r.found;
	eye = r.eye;
	_total_taken += 1;
	return _candidates.data() + r.first;
}

Array AISensingJob::get_candidates(Object *observer, int64_t tick) {
	Array out;
	const int64_t i = find_request(observer, tick);
	if (i < 0) {
		return out;
	}
	if (_handle != 0) {
		_scheduler->finish(_handle);
	}
	const Request &r = _requests[size_t(i)];
	for (int64_t c = 0; c < r.found; ++c) {
		Object *node = ObjectDB::get_instance(_candidates[r.first + size_t(c)].id);
		if (node != nullptr) {
			out.push_back(node);
		}
	}
	return out;
}

Dictionary AISensingJob::get_stats() const {
	Dictionary stats;
	stats["requests"] = _total_requests;
	stats["taken"] = _total_taken;
	stats["last_requests"] = int64_t(_requests.size());
	return stats;
}

void AISensingJob::reset_stats() {
	_total_requests = 0;
	_total_taken = 0;
}

void AISensingJob::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "scheduler", "grid"), &AISensingJob::setup);
	ClassDB::bind_method(D_METHOD("set_geometry", "geometry"), &AISensingJob::set_geometry); // Claude 2026-11-09, step 4
	ClassDB::bind_method(D_METHOD("add_request", "observer", "eye_yaw", "reach", "max_candidates", "sight_settings"), &AISensingJob::add_request);
	ClassDB::bind_method(D_METHOD("start", "tick"), &AISensingJob::start);
	ClassDB::bind_method(D_METHOD("has_result", "observer", "tick"), &AISensingJob::has_result);
	ClassDB::bind_method(D_METHOD("get_candidates", "observer", "tick"), &AISensingJob::get_candidates);
	ClassDB::bind_method(D_METHOD("get_stats"), &AISensingJob::get_stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &AISensingJob::reset_stats);
}
