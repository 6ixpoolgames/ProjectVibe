// Written by Claude (claude-opus-5-5), 2026-11-03: input providers / adapters and the composite (spec 5.2, 5.4, 5.5).
// Everything here runs on worker threads and only reads the InputSnapshot it is given.
#pragma once

#include "input_store.h"
#include "span_field.h"

class rcContext;

namespace navcore {

// What a provider writes through. It routes each solid range by the layer's op:
// ADD -> union, CARVE -> subtract, SURFACE -> recolour the tops inside the range.
// Providers never see Recast or the op; they just describe "solid from y0 to y1, surface s".
class SpanWriter {
public:
	SpanWriter(SpanField &field, LayerOp op) :
			m_field(field), m_op(op) {}

	void solid(int cx, int cz, float y0, float y1, uint8_t surface) {
		switch (m_op) {
			case LayerOp::ADD:
				m_field.add_solid(cx, cz, y0, y1, surface);
				break;
			case LayerOp::CARVE:
				m_field.carve(cx, cz, y0, y1);
				break;
			case LayerOp::SURFACE:
				m_field.set_surface(cx, cz, y0, y1, surface);
				break;
		}
	}
	const SpanField &field() const { return m_field; }

private:
	SpanField &m_field;
	LayerOp m_op;
};

struct FillContext {
	const NavConfig &cfg;
	rcContext *rc;
};

// The spec's INavInputProvider. Returns false if some of the region had no data yet
// (the tile is then marked provisional and rebuilt when the data arrives).
class InputProvider {
public:
	virtual ~InputProvider() = default;
	virtual bool fill_spans(const LayerSnapshot &layer, SpanWriter &out, const FillContext &ctx) const = 0;
};

// Heightmap: one solid per column, from the world floor up to the sampled height. No rasterization.
class HeightmapAdapter : public InputProvider {
public:
	bool fill_spans(const LayerSnapshot &layer, SpanWriter &out, const FillContext &ctx) const override;
};

// Triangle meshes: Recast rasterization into a scratch heightfield, then copied over as spans.
// Triangles steeper than max_slope_deg become solid-but-not-walkable (surface 0).
class MeshAdapter : public InputProvider {
public:
	bool fill_spans(const LayerSnapshot &layer, SpanWriter &out, const FillContext &ctx) const override;
};

// Applies every layer in order into one SpanField.
class CompositeProvider {
public:
	// Returns false if any layer was missing data somewhere in the field (=> provisional tile).
	bool fill_spans(const InputSnapshot &snap, SpanField &field, const FillContext &ctx) const;

private:
	HeightmapAdapter m_heightmap;
	MeshAdapter m_mesh;
};

} // namespace navcore
