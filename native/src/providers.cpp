// Written by Claude (claude-opus-5-5), 2026-11-03: input providers / adapters and the composite (spec 5.2, 5.4, 5.5).
#include "providers.h"

#include <Recast.h>

#include <algorithm>
#include <cmath>
#include <vector>

namespace navcore {

bool HeightmapAdapter::fill_spans(const LayerSnapshot &layer, SpanWriter &out, const FillContext &ctx) const {
	if (layer.chunks.empty()) {
		return layer.info.samples_x == 0; // a layer with no data at all yet isn't "missing" anything
	}
	const SpanField &f = out.field();
	bool complete = true;
	for (int cz = 0; cz < f.depth(); ++cz) {
		const float wz = f.cell_center_z(cz);
		for (int cx = 0; cx < f.width(); ++cx) {
			const float wx = f.cell_center_x(cx);
			const HeightChunk *chunk = layer.find_chunk_at(wx, wz);
			if (!chunk) {
				complete = false; // neighbour chunk not submitted yet
				continue;
			}
			const float h = chunk->height_at(wx, wz);
			out.solid(cx, cz, ctx.cfg.world_floor_y, h, chunk->surface_at(wx, wz));
		}
	}
	return complete;
}

bool MeshAdapter::fill_spans(const LayerSnapshot &layer, SpanWriter &out, const FillContext &ctx) const {
	if (layer.meshes.empty()) {
		return true;
	}
	const SpanField &f = out.field();
	const NavConfig &cfg = ctx.cfg;

	rcHeightfield *hf = rcAllocHeightfield();
	if (!hf) {
		return true;
	}
	const float bmin[3] = { f.origin_x(), cfg.world_floor_y, f.origin_z() };
	const float bmax[3] = { f.origin_x() + f.width() * f.cell_size(), cfg.world_ceiling_y, f.origin_z() + f.depth() * f.cell_size() };
	if (!rcCreateHeightfield(ctx.rc, *hf, f.width(), f.depth(), bmin, bmax, cfg.cell_size, cfg.cell_height)) {
		rcFreeHeightField(hf);
		return true;
	}

	const float walkable_cos = std::cos(cfg.max_slope_deg * 3.14159265f / 180.0f);
	std::vector<unsigned char> areas;
	for (const auto &mesh : layer.meshes) {
		const int ntris = int(mesh->tris.size() / 3);
		areas.assign(size_t(ntris), 0);
		for (int t = 0; t < ntris; ++t) {
			// Same test as rcMarkWalkableTriangles, but writing our surface id instead of RC_WALKABLE_AREA.
			const float *v0 = &mesh->verts[size_t(mesh->tris[size_t(t * 3 + 0)]) * 3];
			const float *v1 = &mesh->verts[size_t(mesh->tris[size_t(t * 3 + 1)]) * 3];
			const float *v2 = &mesh->verts[size_t(mesh->tris[size_t(t * 3 + 2)]) * 3];
			const float e0[3] = { v1[0] - v0[0], v1[1] - v0[1], v1[2] - v0[2] };
			const float e1[3] = { v2[0] - v0[0], v2[1] - v0[1], v2[2] - v0[2] };
			const float n[3] = { e0[1] * e1[2] - e0[2] * e1[1], e0[2] * e1[0] - e0[0] * e1[2], e0[0] * e1[1] - e0[1] * e1[0] };
			const float len = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
			if (len > 0.0f && n[1] / len > walkable_cos) {
				areas[size_t(t)] = mesh->surface;
			}
		}
		rcRasterizeTriangles(ctx.rc, mesh->verts.data(), int(mesh->verts.size() / 3), mesh->tris.data(), areas.data(),
				ntris, *hf, cfg.walkable_climb_cells());
	}

	// Recast rasterizes a closed mesh as thin shells (top face, bottom face), not a filled volume.
	// That is right for ADD (you stand on the top). For CARVE it would only cut thin slices, so a
	// carving mesh fills each column from its lowest to its highest point instead.
	const bool fill_columns = layer.info.op == LayerOp::CARVE;
	for (int cz = 0; cz < f.depth(); ++cz) {
		for (int cx = 0; cx < f.width(); ++cx) {
			const rcSpan *first = hf->spans[cx + cz * f.width()];
			if (!first) {
				continue;
			}
			if (fill_columns) {
				unsigned int lo = first->smin, hi = first->smax;
				for (const rcSpan *s = first; s; s = s->next) {
					lo = std::min(lo, (unsigned int)s->smin);
					hi = std::max(hi, (unsigned int)s->smax);
				}
				out.solid(cx, cz, cfg.world_floor_y + lo * cfg.cell_height, cfg.world_floor_y + hi * cfg.cell_height, SURFACE_NONE);
				continue;
			}
			for (const rcSpan *s = first; s; s = s->next) {
				out.solid(cx, cz, cfg.world_floor_y + s->smin * cfg.cell_height,
						cfg.world_floor_y + s->smax * cfg.cell_height, uint8_t(s->area));
			}
		}
	}
	rcFreeHeightField(hf);
	return true;
}

bool CompositeProvider::fill_spans(const InputSnapshot &snap, SpanField &field, const FillContext &ctx) const {
	bool complete = true;
	for (const LayerSnapshot &layer : snap.layers) { // already sorted by order
		SpanWriter writer(field, layer.info.op);
		const InputProvider &provider = layer.info.kind == AdapterKind::HEIGHTMAP
				? static_cast<const InputProvider &>(m_heightmap)
				: static_cast<const InputProvider &>(m_mesh);
		if (!provider.fill_spans(layer, writer, ctx)) {
			complete = false;
		}
	}
	return complete;
}

} // namespace navcore
