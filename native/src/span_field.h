// Written by Claude (claude-opus-5-5), 2026-11-03: per-column solid span lists, the universal nav input (spec 5.2).
#pragma once

#include <cstdint>
#include <vector>

namespace navcore {

struct Span {
	float y0; // bottom of solid, world units
	float y1; // top of solid = the surface something could stand on
	uint8_t surface; // nav surface type of the top (0 = solid but not walkable)
};

// A grid of columns covering one tile plus its border. Each column holds a sorted list of
// disjoint solid spans. Input layers write into it; the ground builder turns it into a
// Recast heightfield afterwards.
//
// Why our own format instead of writing straight into Recast's rcHeightfield:
// Recast can only ADD spans. Layers also need CARVE (caves, craters) and SURFACE (roads),
// so we composite here first and hand Recast the final result.
class SpanField {
public:
	void reset(int width, int depth, float origin_x, float origin_z, float cell_size);

	int width() const { return m_width; }
	int depth() const { return m_depth; }
	float origin_x() const { return m_origin_x; } // world x of the min corner of cell (0, 0)
	float origin_z() const { return m_origin_z; }
	float cell_size() const { return m_cell_size; }
	float cell_center_x(int cx) const { return m_origin_x + (cx + 0.5f) * m_cell_size; }
	float cell_center_z(int cz) const { return m_origin_z + (cz + 0.5f) * m_cell_size; }

	std::vector<Span> &column(int cx, int cz) { return m_columns[size_t(cx + cz * m_width)]; }
	const std::vector<Span> &column(int cx, int cz) const { return m_columns[size_t(cx + cz * m_width)]; }

	// Union. Where spans overlap, the surface of whichever span reaches higher wins.
	void add_solid(int cx, int cz, float y0, float y1, uint8_t surface);
	// Subtract. Pieces that remain keep their surface type.
	void carve(int cx, int cz, float y0, float y1);
	// Change the surface type of every span whose top lies inside [y0, y1].
	void set_surface(int cx, int cz, float y0, float y1, uint8_t surface);

private:
	int m_width = 0;
	int m_depth = 0;
	float m_origin_x = 0.0f;
	float m_origin_z = 0.0f;
	float m_cell_size = 1.0f;
	std::vector<std::vector<Span>> m_columns;
};

} // namespace navcore
