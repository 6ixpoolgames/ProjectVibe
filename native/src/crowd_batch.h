// Written by Claude (claude-opus-5-5), 2026-11-17 (C++ bundle stage 3, pawn spec 8.22): the crowd mover's batch in C++. CrowdMover.gd
// gathers the AI pawns walking on the ground each tick and hands their moves here as plain lists; this works out where each one
// ends up, spread over the job scheduler's worker threads, and says which ones it couldn't move so CrowdMover moves those by
// physics. CrowdMover._move_batch is the GDScript version, used where this library isn't available.
//
// For each pawn, in three steps, as the GDScript version:
//   1. Where it would go: its move for the tick, flat.
//   2. Separation: pushed apart from every pawn it overlaps (the other movers where they'd go, the rest where they stand), half the
//      push each between two movers, all of it against a pawn that isn't moving with the crowd. Every push is worked out from the
//      same positions, so the order of the pawns changes nothing.
//   3. Walls and the ground. The owner's call in the code audit: walls belong in navigation. So a pawn on the nav mesh walks along it
//      (Detour's moveAlongSurface for its nav tier, what Unreal calls NavWalking): it slides along the nav mesh's edge, which is the
//      walls less the tier's radius, instead of crossing it. Then the ground under where it ends up, from SightGeometry's copy of the
//      level (the same triangles and shapes physics has), within the step it may climb.
//
// What each pawn's status says (get_statuses):
//   MOVED (1): done; the position returned is where it stands.
//   BY_PHYSICS (0): no ground within its step there, or too steep: CrowdMover moves it by physics, which handles the edge or the fall.
//   CHECK_WALLS (2): not walked along the nav mesh, so CrowdMover checks walls and ground with physics, as before this class: no nav
//     mesh under it (none built there, or it's off the edge), no NavServer, or a body wider than its nav tier's radius (the nav mesh
//     would let it stand partly inside a wall; set the tiers' radii, NavServer.configure's tier_radii, to the pawns' sizes), or a tier of -1
//     (Claude 2026-11-17: a pawn crossing a nav link, a jump or a drop off a ledge, which leaves the nav mesh on purpose). The
//     position returned is where separation pushed it.
//   CHECK_GROUND (3): walked along the nav mesh, but the ground under it needs physics: there's no SightGeometry, or a capsule or
//     cylinder is in the way, which it doesn't work out exactly. The position returned is where the walk ended, at its old height.
//
// Thread rule: the lists are copied before any worker starts, the nav mesh only changes in NavServer.tick and the geometry in its
// sync, both on the main thread, and move() returns only when every worker is done. Each worker uses a nav query of its own.
#pragma once

#include "job_scheduler.h"
#include "sight_geometry.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class NavServer;

class CrowdBatch : public RefCounted {
	GDCLASS(CrowdBatch, RefCounted)

public:
	enum Status {
		BY_PHYSICS = 0,
		MOVED = 1,
		CHECK_WALLS = 2,
		CHECK_GROUND = 3,
	};

	// The scheduler (null: everything on the calling thread), the geometry for the ground (null: CHECK_GROUND for everyone walked
	// along the nav mesh) and the NavServer (null: CHECK_WALLS for everyone).
	void setup(const Ref<JobScheduler> &scheduler, const Ref<SightGeometry> &geometry, Object *nav_server);
	// CrowdMover's settings, with the same names and meanings.
	void set_settings(double separation_strength, double separation_margin, double max_push_speed, double max_step, int64_t ground_layers,
			double cell_size);

	// One tick's batch. positions, motions, radii, seconds, slopes (steepest walkable rise per metre) and floor_normals (the least
	// upward normal it can stand on) as CrowdMover._move_batch has them, plus each pawn's nav tier; obstacle_positions and
	// obstacle_radii are the other pawns. tick is the tick, for the geometry's sync. Returns a position for each pawn; see the top.
	PackedVector3Array move(const PackedVector3Array &positions, const PackedVector3Array &motions, const PackedFloat32Array &radii,
			const PackedFloat32Array &seconds, const PackedFloat32Array &slopes, const PackedFloat32Array &floor_normals,
			const PackedInt32Array &tiers, const PackedVector3Array &obstacle_positions, const PackedFloat32Array &obstacle_radii,
			int64_t tick);
	// What move() decided for each pawn, one Status per pawn.
	PackedByteArray get_statuses() const;
	// For readouts and tests: how many pawns got each status in the last move().
	Dictionary get_stats() const;

protected:
	static void _bind_methods();

private:
	void run_pawns(int32_t begin, int32_t end);
	int64_t cell_key(int64_t x, int64_t z) const { return (x << 32) ^ (z & 0xFFFFFFFF); }

	Ref<JobScheduler> _scheduler;
	Ref<SightGeometry> _geometry;
	NavServer *_nav = nullptr;
	uint64_t _nav_id = 0; // to check the NavServer still exists
	int _kind = 0;

	double _separation_strength = 1.0;
	double _separation_margin = 0.1;
	double _max_push_speed = 10.0;
	double _max_step = 0.4;
	uint32_t _ground_layers = 1;
	double _cell_size = 2.0;

	// One tick's lists, copied in, for the workers.
	size_t _count = 0;
	std::vector<Vector3> _from;
	std::vector<Vector3> _wanted;
	std::vector<float> _radii;
	std::vector<float> _seconds;
	std::vector<float> _slopes;
	std::vector<float> _floor_normals;
	std::vector<int32_t> _tiers;
	std::vector<uint8_t> _walk_on_nav; // the nav mesh may be used for its walls: its tier's radius covers its body
	std::vector<Vector3> _others;
	std::vector<float> _other_radii;
	float _widest = 0.0f;
	std::unordered_map<int64_t, std::vector<int32_t>> _grid; // cell -> index (movers first, then the others)
	// What the workers write, each only its own pawn's place.
	std::vector<Vector3> _result;
	std::vector<uint8_t> _status;
	bool _warned_tier = false;
};

} // namespace godot

VARIANT_ENUM_CAST(CrowdBatch::Status);
