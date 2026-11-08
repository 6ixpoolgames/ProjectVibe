// Written by Claude (claude-opus-5-5), 2026-11-09: a shared grid of pawns for AI sensing's "who's near me" query. Pawn spec 10.4
// and 10.11.
//
// Pawns register when they enter the tree and unregister when they leave (Pawn.gd, through AISensingManager). The grid is rebuilt
// at most once a tick, on the first query of that tick, from each pawn's position and team, and then every pawn's query reads it.
//
// Why it exists: the GDScript fallback asks the physics engine with a sphere query per sensing pass, and Godot builds a dictionary
// for every pawn it finds. In ai_stress that was about 61 µs a pass, 1.5 ms a tick for 200 pawns. Here a query only looks at the
// grid cells in range. It also returns the nearest pawns first, so the max_candidates cap keeps the ones that matter.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace godot {

class Node3D;

class AIPawnGrid : public RefCounted {
	GDCLASS(AIPawnGrid, RefCounted)

public:
	void track(Object *pawn);
	void untrack(Object *pawn);
	int64_t tracked_count() const;

	// Size of a grid cell, in metres. Roughly the usual sense range divided by 3 works well.
	void set_cell_size(double size);
	double get_cell_size() const;

	// Pawns within radius of origin whose team isn't own_team, nearest first, at most max_results, never `exclude`. tick says when
	// the positions were read: the first query of a new tick rebuilds the grid.
	Array query(const Vector3 &origin, double radius, int64_t own_team, Object *exclude, int64_t max_results, int64_t tick);

protected:
	static void _bind_methods();

private:
	struct Entry {
		Node3D *node;
		Vector3 position;
		int64_t team;
	};

	void rebuild(int64_t tick);
	int64_t cell_key(int64_t x, int64_t z) const { return (x << 32) ^ (z & 0xFFFFFFFF); }

	std::unordered_set<uint64_t> _tracked;
	std::vector<Entry> _entries;
	std::unordered_map<int64_t, std::vector<uint32_t>> _cells; // cell -> indexes into _entries
	std::vector<std::pair<double, uint32_t>> _found; // reused by query
	double _cell_size = 8.0;
	int64_t _built_tick = -1;
	bool _dirty = true;
};

} // namespace godot
