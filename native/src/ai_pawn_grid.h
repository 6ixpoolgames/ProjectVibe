// Written by Claude (claude-opus-5-5), 2026-11-09: a shared grid of pawns for AI sensing's "who's near me" query. Pawn spec 10.4
// and 10.11.
//
// Claude 2026-11-09 (scaling spec step 1): built from the PawnTable instead of tracking pawns itself. It's rebuilt at most once a
// tick, on the first query of that tick, after the table has read its rows, and then every pawn's query reads it. Pawns are in the
// table's slot order, which is by entity id, so equally distant pawns now come back in the same order on every machine and every
// run (before, ties went by hash order).
//
// Why it exists: the GDScript fallback asks the physics engine with a sphere query per sensing pass, and Godot builds a dictionary
// for every pawn it finds. In ai_stress that was about 61 µs a pass, 1.5 ms a tick for 200 pawns. Here a query only looks at the
// grid cells in range. It also returns the nearest pawns first, so the max_candidates cap keeps the ones that matter.
#pragma once

#include "pawn_table.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class AIPawnGrid : public RefCounted {
	GDCLASS(AIPawnGrid, RefCounted)

public:
	// The table it reads. Claude 2026-11-09: replaces track() and untrack(); pawns join and leave the table instead.
	void set_table(const Ref<PawnTable> &table);
	Ref<PawnTable> get_table() const;

	// Size of a grid cell, in metres. Roughly the usual sense range divided by 3 works well.
	void set_cell_size(double size);
	double get_cell_size() const;

	// Pawns within radius of origin whose team isn't own_team, nearest first, at most max_results, never `exclude`. tick says when
	// the positions were read: the first query of a new tick refreshes the table and rebuilds the grid.
	Array query(const Vector3 &origin, double radius, int64_t own_team, Object *exclude, int64_t max_results, int64_t tick);

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
};

} // namespace godot
