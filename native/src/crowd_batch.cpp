// Written by Claude (claude-opus-5-5), 2026-11-17 (C++ bundle stage 3): see crowd_batch.h.
#include "crowd_batch.h"

#include "nav_server.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <DetourNavMeshQuery.h>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
// How far off the nav mesh, across, a pawn may stand and still walk along it. Further than that (pushed off by physics, say), it's
// checked by physics instead, which puts it back on its own.
constexpr float NAV_TOLERANCE = 0.1f;
// A body may be this much wider than its tier's radius and still walk along the nav mesh: rounding, not a real difference.
constexpr float TIER_RADIUS_SLACK = 0.01f;
} // namespace

void CrowdBatch::setup(const Ref<JobScheduler> &scheduler, const Ref<SightGeometry> &geometry, Object *nav_server) {
	_scheduler = scheduler;
	_geometry = geometry;
	_nav = Object::cast_to<NavServer>(nav_server);
	_nav_id = _nav ? _nav->get_instance_id() : 0;
	if (_scheduler.is_valid()) {
		// A first guess of 3 µs a pawn (the GDScript batch was about 10); measured from the first run on.
		_kind = _scheduler->kind("crowd", 3.0);
	}
}

void CrowdBatch::set_settings(double separation_strength, double separation_margin, double max_push_speed, double max_step,
		int64_t ground_layers, double cell_size) {
	_separation_strength = separation_strength;
	_separation_margin = separation_margin;
	_max_push_speed = max_push_speed;
	_max_step = max_step;
	_ground_layers = uint32_t(ground_layers);
	_cell_size = std::max(cell_size, 0.25);
}

PackedVector3Array CrowdBatch::move(const PackedVector3Array &positions, const PackedVector3Array &motions, const PackedFloat32Array &radii,
		const PackedFloat32Array &seconds, const PackedFloat32Array &slopes, const PackedFloat32Array &floor_normals,
		const PackedInt32Array &tiers, const PackedVector3Array &obstacle_positions, const PackedFloat32Array &obstacle_radii, int64_t tick) {
	PackedVector3Array out;
	_count = size_t(positions.size());
	_status.assign(_count, BY_PHYSICS);
	if (_count == 0) {
		return out;
	}
	if (motions.size() != int64_t(_count) || radii.size() != int64_t(_count) || seconds.size() != int64_t(_count) ||
			slopes.size() != int64_t(_count) || floor_normals.size() != int64_t(_count) || tiers.size() != int64_t(_count) ||
			obstacle_positions.size() != obstacle_radii.size()) {
		UtilityFunctions::push_error("CrowdBatch.move: the lists must all have one entry per pawn (and the obstacles' two match).");
		out = positions; // every status is BY_PHYSICS
		return out;
	}
	// The NavServer is a singleton that lives as long as the engine, but a test could free one it made.
	if (_nav && ObjectDB::get_instance(_nav_id) == nullptr) {
		_nav = nullptr;
	}
	const bool nav_ready = _nav != nullptr && _nav->ground().ready();
	// Copied in, so the workers read plain data only.
	_from.resize(_count);
	_wanted.resize(_count);
	_radii.resize(_count);
	_seconds.resize(_count);
	_slopes.resize(_count);
	_floor_normals.resize(_count);
	_tiers.resize(_count);
	_walk_on_nav.assign(_count, 0);
	_widest = 0.0f;
	for (size_t i = 0; i < _count; ++i) {
		_from[i] = positions[int64_t(i)];
		const Vector3 motion = motions[int64_t(i)];
		_wanted[i] = _from[i] + Vector3(motion.x, 0.0f, motion.z); // 1. where it would go, flat
		_radii[i] = radii[int64_t(i)];
		_seconds[i] = seconds[int64_t(i)];
		_slopes[i] = slopes[int64_t(i)];
		_floor_normals[i] = floor_normals[int64_t(i)];
		_tiers[i] = tiers[int64_t(i)];
		_widest = std::max(_widest, _radii[i]);
		if (nav_ready) {
			// Claude 2026-11-17: a tier of -1 is a pawn crossing a nav link (CrowdMover): a jump or a walk off a ledge leaves the nav
			// mesh on purpose, which walking along it would stop at the edge. It's checked by physics until it's across.
			const bool on_link = _tiers[i] < 0;
			const bool covered = !on_link && _radii[i] <= _nav->tier_radius(_tiers[i]) + TIER_RADIUS_SLACK;
			_walk_on_nav[i] = covered ? 1 : 0;
			if (!covered && !on_link && !_warned_tier) {
				_warned_tier = true;
				UtilityFunctions::push_warning("CrowdBatch: a pawn ", _radii[i], " m wide (its radius) walks on nav tier ", _tiers[i], ", whose radius is ",
						_nav->tier_radius(_tiers[i]), " m, so its walls are checked by physics instead of the nav mesh. Set the nav tiers' radii (NavServer.configure, tier_radii) to the pawns' sizes.");
			}
		}
	}
	const size_t others = size_t(obstacle_positions.size());
	_others.resize(others);
	_other_radii.resize(others);
	for (size_t j = 0; j < others; ++j) {
		_others[j] = obstacle_positions[int64_t(j)];
		_other_radii[j] = obstacle_radii[int64_t(j)];
		_widest = std::max(_widest, _other_radii[j]);
	}
	// The grid for separation, on this thread before the workers start: movers where they'd go, the others where they stand.
	for (auto &cell : _grid) {
		cell.second.clear(); // keep the memory for the next tick
	}
	auto add = [&](const Vector3 &at, int32_t index) {
		const int64_t x = int64_t(std::floor(at.x / _cell_size));
		const int64_t z = int64_t(std::floor(at.z / _cell_size));
		_grid[cell_key(x, z)].push_back(index);
	};
	for (size_t i = 0; i < _count; ++i) {
		add(_wanted[i], int32_t(i));
	}
	for (size_t j = 0; j < others; ++j) {
		add(_others[j], int32_t(_count + j));
	}
	if (_geometry.is_valid()) {
		_geometry->sync(tick); // what changed in the level, on this thread, before any worker reads it
	}
	_result.assign(_count, Vector3());
	if (_scheduler.is_valid()) {
		const int64_t handle = _scheduler->start(_kind, int32_t(_count), [this](int32_t begin, int32_t end) { run_pawns(begin, end); });
		_scheduler->finish(handle);
	} else {
		run_pawns(0, int32_t(_count));
	}
	out.resize(int64_t(_count));
	for (size_t i = 0; i < _count; ++i) {
		out[int64_t(i)] = _result[i];
	}
	return out;
}

// On any thread: reads the copied lists, the nav mesh and the geometry, and writes only pawns begin..end's places.
void CrowdBatch::run_pawns(int32_t begin, int32_t end) {
	const navcore::GroundDomain *ground = _nav ? &_nav->ground() : nullptr;
	dtNavMeshQuery *query = ground ? ground->new_query() : nullptr; // this batch's own: a query can't be shared between threads
	const SightGeometry *geometry = _geometry.ptr();
	for (int32_t index = begin; index < end; ++index) {
		const size_t i = size_t(index);
		// 2. Separation: every overlap, from the same positions.
		Vector3 push;
		const float reach = _radii[i] + _widest + float(_separation_margin);
		const int64_t span = int64_t(std::ceil(reach / _cell_size));
		const int64_t cx = int64_t(std::floor(_wanted[i].x / _cell_size));
		const int64_t cz = int64_t(std::floor(_wanted[i].z / _cell_size));
		for (int64_t dx = -span; dx <= span; ++dx) {
			for (int64_t dz = -span; dz <= span; ++dz) {
				auto cell = _grid.find(cell_key(cx + dx, cz + dz));
				if (cell == _grid.end()) {
					continue;
				}
				for (int32_t j : cell->second) {
					if (size_t(j) == i) {
						continue;
					}
					const bool mover = size_t(j) < _count;
					const Vector3 &other_at = mover ? _wanted[size_t(j)] : _others[size_t(j) - _count];
					const float other_radius = mover ? _radii[size_t(j)] : _other_radii[size_t(j) - _count];
					const Vector2 apart(_wanted[i].x - other_at.x, _wanted[i].z - other_at.z);
					const double needed = double(_radii[i]) + double(other_radius) + _separation_margin;
					const double distance = apart.length();
					if (distance >= needed) {
						continue;
					}
					// Exactly on top of each other: a direction from the pair's numbers, so the two don't pick the same one.
					const Vector2 away = distance > 0.0001 ? apart / real_t(distance) : Vector2::from_angle(real_t(double(int64_t(i) * 7 + j * 13)));
					const double share = mover ? 0.5 : 1.0;
					push += Vector3(away.x, 0.0f, away.y) * real_t((needed - distance) * share * _separation_strength);
				}
			}
		}
		const double most = _max_push_speed * double(_seconds[i]);
		if (push.length() > most) {
			push = push.normalized() * real_t(most);
		}
		const Vector3 from = _from[i];
		const Vector3 pushed = _wanted[i] + push;
		// 3. Walls, along the nav mesh.
		if (!_walk_on_nav[i] || query == nullptr) {
			_result[i] = pushed;
			_status[i] = CHECK_WALLS;
			continue;
		}
		const float flat = Vector2(pushed.x - from.x, pushed.z - from.z).length();
		const float allowed = float(_max_step) + flat * _slopes[i]; // how far up it may step over this move
		const float start[3] = { from.x, from.y, from.z };
		const float goal[3] = { pushed.x, from.y, pushed.z };
		float walked[3];
		if (!ground->move_along_surface(query, start, goal, _tiers[i], NAV_TOLERANCE, allowed + 0.5f, walked)) {
			_result[i] = pushed;
			_status[i] = CHECK_WALLS; // no nav mesh under it
			continue;
		}
		const Vector3 to(walked[0], from.y, walked[2]);
		// The ground under where it ends up, within that step.
		if (geometry == nullptr) {
			_result[i] = to;
			_status[i] = CHECK_GROUND;
			continue;
		}
		double height = 0.0;
		Vector3 normal;
		const int found = geometry->ground_at(to.x, to.z, double(from.y) + allowed, double(from.y) - allowed - 0.05, _ground_layers, height,
				normal);
		if (found < 0) {
			_result[i] = to;
			_status[i] = CHECK_GROUND;
		} else if (found == 0 || normal.y < _floor_normals[i]) {
			_result[i] = from;
			_status[i] = BY_PHYSICS; // no ground there, or too steep to walk on
		} else {
			_result[i] = Vector3(to.x, real_t(height), to.z);
			_status[i] = MOVED;
		}
	}
	navcore::GroundDomain::free_query(query);
}

PackedByteArray CrowdBatch::get_statuses() const {
	PackedByteArray statuses;
	statuses.resize(int64_t(_status.size()));
	for (size_t i = 0; i < _status.size(); ++i) {
		statuses[int64_t(i)] = _status[i];
	}
	return statuses;
}

Dictionary CrowdBatch::get_stats() const {
	int64_t counts[4] = { 0, 0, 0, 0 };
	for (uint8_t status : _status) {
		counts[std::min<int>(status, 3)] += 1;
	}
	Dictionary stats;
	stats["by_physics"] = counts[BY_PHYSICS];
	stats["moved"] = counts[MOVED];
	stats["check_walls"] = counts[CHECK_WALLS];
	stats["check_ground"] = counts[CHECK_GROUND];
	return stats;
}

void CrowdBatch::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "scheduler", "geometry", "nav_server"), &CrowdBatch::setup);
	ClassDB::bind_method(D_METHOD("set_settings", "separation_strength", "separation_margin", "max_push_speed", "max_step", "ground_layers",
								 "cell_size"),
			&CrowdBatch::set_settings);
	ClassDB::bind_method(D_METHOD("move", "positions", "motions", "radii", "seconds", "slopes", "floor_normals", "tiers",
								 "obstacle_positions", "obstacle_radii", "tick"),
			&CrowdBatch::move);
	ClassDB::bind_method(D_METHOD("get_statuses"), &CrowdBatch::get_statuses);
	ClassDB::bind_method(D_METHOD("get_stats"), &CrowdBatch::get_stats);
	BIND_ENUM_CONSTANT(BY_PHYSICS);
	BIND_ENUM_CONSTANT(MOVED);
	BIND_ENUM_CONSTANT(CHECK_WALLS);
	BIND_ENUM_CONSTANT(CHECK_GROUND);
}
