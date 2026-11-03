// Written by Claude (claude-opus-5-5), 2026-11-03: span list operations used by input layers (spec 5.2, 5.5).
#include "span_field.h"

#include <algorithm>

namespace navcore {

void SpanField::reset(int width, int depth, float origin_x, float origin_z, float cell_size) {
	m_width = width;
	m_depth = depth;
	m_origin_x = origin_x;
	m_origin_z = origin_z;
	m_cell_size = cell_size;
	m_columns.assign(size_t(width) * size_t(depth), {});
}

void SpanField::add_solid(int cx, int cz, float y0, float y1, uint8_t surface) {
	if (y1 <= y0) {
		return;
	}
	std::vector<Span> &col = column(cx, cz);
	Span merged{ y0, y1, surface };
	std::vector<Span> out;
	out.reserve(col.size() + 1);
	for (const Span &s : col) {
		const bool disjoint = s.y1 < merged.y0 || s.y0 > merged.y1;
		if (disjoint) {
			out.push_back(s);
			continue;
		}
		// Overlapping or touching: absorb it. The higher top decides the surface.
		merged.y0 = std::min(merged.y0, s.y0);
		if (s.y1 > merged.y1) {
			merged.y1 = s.y1;
			merged.surface = s.surface;
		}
	}
	auto pos = std::lower_bound(out.begin(), out.end(), merged,
			[](const Span &a, const Span &b) { return a.y0 < b.y0; });
	out.insert(pos, merged);
	col.swap(out);
}

void SpanField::carve(int cx, int cz, float y0, float y1) {
	if (y1 <= y0) {
		return;
	}
	std::vector<Span> &col = column(cx, cz);
	std::vector<Span> out;
	out.reserve(col.size() + 1);
	for (const Span &s : col) {
		if (s.y1 <= y0 || s.y0 >= y1) {
			out.push_back(s); // untouched
			continue;
		}
		if (s.y0 < y0) {
			out.push_back({ s.y0, y0, s.surface }); // piece below the carve: its new top is the carved floor
		}
		if (s.y1 > y1) {
			out.push_back({ y1, s.y1, s.surface }); // piece above the carve
		}
	}
	col.swap(out);
}

void SpanField::set_surface(int cx, int cz, float y0, float y1, uint8_t surface) {
	for (Span &s : column(cx, cz)) {
		if (s.y1 >= y0 && s.y1 <= y1) {
			s.surface = surface;
		}
	}
}

} // namespace navcore
