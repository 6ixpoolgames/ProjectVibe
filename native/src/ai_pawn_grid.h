// Written by Claude (claude-opus-5-5), 2026-11-09. History: native/CHANGELOG.md.
// AIPawnGrid: a shared grid of pawns for "who's near me" questions: AI sensing's (pawn spec 10.4 and 10.11) and swing hit checks.
//
// GDScript: Pawn.gd makes the one grid over the PawnTable; AISensingManager queries it (or hands it to AISensingJob), and
// MeleeSweepStep asks find_touching for a swing's hits when nothing is rewound.
//
// Built from the PawnTable (scaling spec step 1). It's rebuilt at most once a tick, on the first query of that tick, after the
// table has read its rows, and then every pawn's query reads it. Pawns are in the table's slot order, which is by entity id, so
// equally distant pawns come back in the same order on every machine and every run.
//
// Why it exists: the GDScript fallback asks the physics engine with a sphere query per sensing pass, and Godot builds a dictionary
// for every pawn it finds (in ai_stress about 61 µs a pass, 1.5 ms a tick for 200 pawns). Here a query only looks at the grid
// cells in range. It also returns the nearest pawns first, so the max_candidates cap keeps the ones that matter.
#pragma once

#include "change_guard.h"
#include "pawn_table.h"

#include <godot_cpp/classes/ref.hpp> // godot-cpp 10: Ref<T> isn't pulled in by ref_counted.hpp
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class AIPawnGrid : public RefCounted {
	GDCLASS(AIPawnGrid, RefCounted)

public:
	// The table it reads. Pawns join and leave the table, not the grid.
	void set_table(const Ref<PawnTable> &table);
	Ref<PawnTable> get_table() const;

	// Size of a grid cell, in metres. Roughly the usual sense range divided by 3 works well.
	void set_cell_size(double size);
	double get_cell_size() const;

	// Pawns within radius of origin whose team isn't own_team, nearest first, at most max_results, never `exclude`. tick says when
	// the positions were read: the first query of a new tick refreshes the table and rebuilds the grid.
	Array query(const Vector3 &origin, double radius, int64_t own_team, Object *exclude, int64_t max_results, int64_t tick);

	// For worker jobs (scaling spec step 2). prepare() refreshes the table for this tick and rebuilds the cells if
	// it changed, on the main thread. find_slots() then only reads, so any number of threads can run it at once: the table slots of
	// pawns within radius of origin whose team isn't own_team, never exclude_slot, nearest first with ties by slot, at most
	// max_results. They go in the first entries of found (the caller's own scratch), and the count is returned.
	void prepare(int64_t tick);

	// Swing hit checks, instead of a physics sphere query per spot. The pawns whose bodies (PawnTable::Body) a sphere of radius at
	// any of centres touches, every team, never exclude, in the order a physics query per centre would list them as new: centre by
	// centre, then by slot. The grid only finds who's near; each is then tested
	// exactly at its node's position now, since pawns that already ran this tick have moved since the table was read. A pawn on no
	// collision layer is never touched, as physics wouldn't find it.
	Array find_touching(const PackedVector3Array &centres, double radius, Object *exclude, int64_t tick);
	// Jobs reading find_slots() add themselves here (change_guard.h), and a rebuild waits for them, set_cell_size's too.
	navcore::ChangeGuard &change_guard() { return _change_guard; }
	// See prepare() above.
	size_t find_slots(const Vector3 &origin, double radius, int64_t own_team, int64_t exclude_slot, size_t max_results,
			std::vector<std::pair<double, uint32_t>> &found) const;

protected:
	static void _bind_methods();

private:
	void rebuild();
	int64_t cell_key(int64_t x, int64_t z) const { return (x << 32) ^ (z & 0xFFFFFFFF); }

	Ref<PawnTable> _table;
	std::unordered_map<int64_t, std::vector<uint32_t>> _cells; // cell -> table slots
	std::vector<std::pair<double, uint32_t>> _found; // reused by query
	double _cell_size = 8.0;
	int64_t _built_version = -1; // the table's version the cells were built from
	navcore::ChangeGuard _change_guard;
};

} // namespace godot
