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

// Claude 2026-11-17 (C++ bundle stage 2, from the code audit): add_solid and carve edit the column in place. Both used to build a
// new list for every call, one heap allocation per cell per input layer in every tile build. A column is always sorted from the
// bottom up, and its spans never overlap or touch (touching ones are merged), so the spans an edit concerns are always one run of
// neighbours: found, replaced by the result, and the rest left where they are. The results are the same as before.
void SpanField::add_solid(int cx, int cz, float y0, float y1, uint8_t surface) {
	if (y1 <= y0) {
		return;
	}
	std::vector<Span> &col = column(cx, cz);
	Span merged{ y0, y1, surface };
	// The first span reaching up to the new one (touching counts), then every span from there that starts at or below its top.
	auto first = std::find_if(col.begin(), col.end(), [&](const Span &s) { return s.y1 >= merged.y0; });
	auto last = first;
	while (last != col.end() && last->y0 <= merged.y1) {
		// Overlapping or touching: absorb it. The higher top decides the surface.
		merged.y0 = std::min(merged.y0, last->y0);
		if (last->y1 > merged.y1) {
			merged.y1 = last->y1;
			merged.surface = last->surface;
		}
		++last;
	}
	if (first == last) {
		col.insert(first, merged); // nothing to absorb: it goes in between
	} else {
		*first = merged; // the first absorbed span's place is the merged span's, and the rest go
		col.erase(first + 1, last);
	}
}

void SpanField::carve(int cx, int cz, float y0, float y1) {
	if (y1 <= y0) {
		return;
	}
	std::vector<Span> &col = column(cx, cz);
	// The spans the carve reaches into: from the first whose top is above its floor, while they start below its ceiling.
	auto first = std::find_if(col.begin(), col.end(), [&](const Span &s) { return s.y1 > y0; });
	auto last = first;
	while (last != col.end() && last->y0 < y1) {
		++last;
	}
	if (first == last) {
		return; // untouched
	}
	// At most two pieces are left: below the carve, from the lowest span it reaches (its new top is the carved floor), and above
	// it, from the highest.
	Span pieces[2];
	int count = 0;
	if (first->y0 < y0) {
		pieces[count++] = { first->y0, y0, first->surface };
	}
	const Span &top = *(last - 1);
	if (top.y1 > y1) {
		pieces[count++] = { y1, top.y1, top.surface };
	}
	const auto at = col.erase(first, last);
	col.insert(at, pieces, pieces + count);
}

void SpanField::set_surface(int cx, int cz, float y0, float y1, uint8_t surface) {
	for (Span &s : column(cx, cz)) {
		if (s.y1 >= y0 && s.y1 <= y1) {
			s.surface = surface;
		}
	}
}

} // namespace navcore
