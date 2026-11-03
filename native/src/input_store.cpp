// Written by Claude (claude-opus-5-5), 2026-11-03: input layers and their submitted data (spec 5.3, 5.7).
#include "input_store.h"

#include <algorithm>
#include <cmath>

namespace navcore {

// ---- HeightChunk -------------------------------------------------------------------------------

float HeightChunk::height_at(float wx, float wz) const {
	const float fx = (wx - origin_x) / spacing;
	const float fz = (wz - origin_z) / spacing;
	const int ix = std::clamp(int(std::floor(fx)), 0, samples_x - 2);
	const int iz = std::clamp(int(std::floor(fz)), 0, samples_z - 2);
	const float u = std::clamp(fx - ix, 0.0f, 1.0f);
	const float v = std::clamp(fz - iz, 0.0f, 1.0f);

	const float a = heights[size_t(ix + iz * samples_x)]; //  a --- b
	const float b = heights[size_t(ix + 1 + iz * samples_x)]; //  |  /  |
	const float c = heights[size_t(ix + (iz + 1) * samples_x)]; //  c --- d
	const float d = heights[size_t(ix + 1 + (iz + 1) * samples_x)];
	if (u + v <= 1.0f) {
		return a + (b - a) * u + (c - a) * v; // triangle a-b-c
	}
	return d + (c - d) * (1.0f - u) + (b - d) * (1.0f - v); // triangle b-d-c
}

uint8_t HeightChunk::surface_at(float wx, float wz) const {
	if (surfaces.empty()) {
		return SURFACE_DEFAULT;
	}
	const int ix = std::clamp(int(std::lround((wx - origin_x) / spacing)), 0, samples_x - 1);
	const int iz = std::clamp(int(std::lround((wz - origin_z) / spacing)), 0, samples_z - 1);
	return surfaces[size_t(ix + iz * samples_x)];
}

WorldRect HeightChunk::rect() const {
	return { origin_x, origin_z, origin_x + (samples_x - 1) * spacing, origin_z + (samples_z - 1) * spacing };
}

// ---- LayerSnapshot -----------------------------------------------------------------------------

const HeightChunk *LayerSnapshot::find_chunk_at(float wx, float wz) const {
	const ChunkKey key{ int32_t(std::floor(wx / info.chunk_world_x())), int32_t(std::floor(wz / info.chunk_world_z())) };
	auto it = chunks.find(key);
	return it == chunks.end() ? nullptr : it->second.get();
}

// ---- InputStore --------------------------------------------------------------------------------

InputStore::Layer *InputStore::find(int id) {
	for (Layer &l : m_layers) {
		if (l.info.id == id) {
			return &l;
		}
	}
	return nullptr;
}

const InputStore::Layer *InputStore::find(int id) const {
	for (const Layer &l : m_layers) {
		if (l.info.id == id) {
			return &l;
		}
	}
	return nullptr;
}

int InputStore::add_layer(AdapterKind kind, LayerOp op, int order, const std::array<uint8_t, 256> &surface_map) {
	Layer layer;
	layer.info.id = m_next_id++;
	layer.info.kind = kind;
	layer.info.op = op;
	layer.info.order = order;
	layer.info.surface_map = surface_map;
	m_layers.push_back(std::move(layer));
	std::stable_sort(m_layers.begin(), m_layers.end(), [](const Layer &a, const Layer &b) {
		return a.info.order != b.info.order ? a.info.order < b.info.order : a.info.id < b.info.id;
	});
	return m_next_id - 1;
}

bool InputStore::remove_layer(int id, WorldRect &out_dirty, bool &out_had_data) {
	for (auto it = m_layers.begin(); it != m_layers.end(); ++it) {
		if (it->info.id != id) {
			continue;
		}
		out_had_data = false;
		for (auto &kv : it->chunks) {
			if (!out_had_data) {
				out_dirty = kv.second->rect();
				out_had_data = true;
			} else {
				out_dirty.include(kv.second->rect());
			}
		}
		for (auto &kv : it->meshes) {
			if (!out_had_data) {
				out_dirty = kv.second->bounds;
				out_had_data = true;
			} else {
				out_dirty.include(kv.second->bounds);
			}
		}
		m_layers.erase(it); // in-flight builds keep their own references, so this is safe
		return true;
	}
	return false;
}

bool InputStore::has_layer(int id) const {
	return find(id) != nullptr;
}

const LayerInfo *InputStore::layer_info(int id) const {
	const Layer *l = find(id);
	return l ? &l->info : nullptr;
}

bool InputStore::submit_heightmap(int layer_id, ChunkKey chunk, int samples_x, int samples_z, float spacing,
		std::vector<float> &&heights, const uint8_t *materials, size_t material_count,
		WorldRect &out_dirty, std::string &err) {
	Layer *layer = find(layer_id);
	if (!layer) {
		err = "unknown layer";
		return false;
	}
	if (layer->info.kind != AdapterKind::HEIGHTMAP) {
		err = "layer is not a heightmap layer";
		return false;
	}
	if (samples_x < 2 || samples_z < 2 || spacing <= 0.0f) {
		err = "heightmap needs at least 2x2 samples and spacing > 0";
		return false;
	}
	if (heights.size() != size_t(samples_x) * size_t(samples_z)) {
		err = "heights size does not match samples_x * samples_z";
		return false;
	}
	if (material_count != 0 && material_count != heights.size()) {
		err = "materials must be empty or one per sample";
		return false;
	}
	LayerInfo &info = layer->info;
	if (info.samples_x == 0) {
		info.samples_x = samples_x;
		info.samples_z = samples_z;
		info.spacing = spacing;
	} else if (info.samples_x != samples_x || info.samples_z != samples_z || std::fabs(info.spacing - spacing) > 1e-6f) {
		err = "all chunks in a layer must have the same sample count and spacing";
		return false;
	}

	auto c = std::make_shared<HeightChunk>();
	c->key = chunk;
	c->samples_x = samples_x;
	c->samples_z = samples_z;
	c->spacing = spacing;
	c->origin_x = chunk.x * info.chunk_world_x();
	c->origin_z = chunk.z * info.chunk_world_z();
	c->heights = std::move(heights);
	if (material_count != 0) {
		c->surfaces.resize(material_count);
		for (size_t i = 0; i < material_count; ++i) {
			c->surfaces[i] = info.surface_map[materials[i]];
		}
	}
	c->version = m_next_version++;
	out_dirty = c->rect();
	layer->chunks[chunk] = std::move(c); // replaces any older copy; builds holding it keep it alive
	return true;
}

bool InputStore::release_chunk(int layer_id, ChunkKey chunk, WorldRect &out_dirty) {
	Layer *layer = find(layer_id);
	if (!layer) {
		return false;
	}
	auto it = layer->chunks.find(chunk);
	if (it == layer->chunks.end()) {
		return false;
	}
	out_dirty = it->second->rect();
	layer->chunks.erase(it);
	return true;
}

bool InputStore::submit_mesh(int layer_id, int64_t id, std::vector<float> &&verts, std::vector<int> &&tris,
		uint8_t surface, WorldRect &out_dirty, std::string &err) {
	Layer *layer = find(layer_id);
	if (!layer) {
		err = "unknown layer";
		return false;
	}
	if (layer->info.kind != AdapterKind::MESH) {
		err = "layer is not a mesh layer";
		return false;
	}
	if (verts.empty() || verts.size() % 3 != 0 || tris.empty() || tris.size() % 3 != 0) {
		err = "mesh needs vertices and triangles";
		return false;
	}
	auto m = std::make_shared<MeshItem>();
	m->id = id;
	m->surface = surface;
	m->bounds = { verts[0], verts[2], verts[0], verts[2] };
	for (size_t i = 0; i < verts.size(); i += 3) {
		m->bounds.min_x = std::min(m->bounds.min_x, verts[i]);
		m->bounds.max_x = std::max(m->bounds.max_x, verts[i]);
		m->bounds.min_z = std::min(m->bounds.min_z, verts[i + 2]);
		m->bounds.max_z = std::max(m->bounds.max_z, verts[i + 2]);
	}
	m->verts = std::move(verts);
	m->tris = std::move(tris);
	m->version = m_next_version++;

	out_dirty = m->bounds;
	auto old = layer->meshes.find(id);
	if (old != layer->meshes.end()) {
		out_dirty.include(old->second->bounds); // a moved mesh dirties where it was, too
	}
	layer->meshes[id] = std::move(m);
	return true;
}

bool InputStore::remove_mesh(int layer_id, int64_t id, WorldRect &out_dirty) {
	Layer *layer = find(layer_id);
	if (!layer) {
		return false;
	}
	auto it = layer->meshes.find(id);
	if (it == layer->meshes.end()) {
		return false;
	}
	out_dirty = it->second->bounds;
	layer->meshes.erase(it);
	return true;
}

bool InputStore::has_walkable_source_in(const WorldRect &r) const {
	for (const Layer &l : m_layers) {
		if (l.info.op != LayerOp::ADD) {
			continue;
		}
		if (l.info.kind == AdapterKind::HEIGHTMAP && !l.chunks.empty()) {
			const float cwx = l.info.chunk_world_x();
			const float cwz = l.info.chunk_world_z();
			const int x0 = int(std::floor(r.min_x / cwx)), x1 = int(std::floor(r.max_x / cwx));
			const int z0 = int(std::floor(r.min_z / cwz)), z1 = int(std::floor(r.max_z / cwz));
			for (int z = z0; z <= z1; ++z) {
				for (int x = x0; x <= x1; ++x) {
					if (l.chunks.count(ChunkKey{ x, z })) {
						return true;
					}
				}
			}
		}
		for (const auto &kv : l.meshes) {
			if (kv.second->bounds.overlaps(r)) {
				return true;
			}
		}
	}
	return false;
}

void InputStore::snapshot(const WorldRect &r, InputSnapshot &out) const {
	out.layers.clear();
	out.layers.reserve(m_layers.size());
	for (const Layer &l : m_layers) {
		LayerSnapshot snap;
		snap.info = l.info;
		if (l.info.kind == AdapterKind::HEIGHTMAP && !l.chunks.empty()) {
			const float cwx = l.info.chunk_world_x();
			const float cwz = l.info.chunk_world_z();
			const int x0 = int(std::floor(r.min_x / cwx)), x1 = int(std::floor(r.max_x / cwx));
			const int z0 = int(std::floor(r.min_z / cwz)), z1 = int(std::floor(r.max_z / cwz));
			for (int z = z0; z <= z1; ++z) {
				for (int x = x0; x <= x1; ++x) {
					auto it = l.chunks.find(ChunkKey{ x, z });
					if (it != l.chunks.end()) {
						snap.chunks.emplace(it->first, it->second);
					}
				}
			}
		}
		for (const auto &kv : l.meshes) {
			if (kv.second->bounds.overlaps(r)) {
				snap.meshes.push_back(kv.second);
			}
		}
		out.layers.push_back(std::move(snap));
	}
}

size_t InputStore::chunk_count() const {
	size_t n = 0;
	for (const Layer &l : m_layers) {
		n += l.chunks.size();
	}
	return n;
}

size_t InputStore::mesh_count() const {
	size_t n = 0;
	for (const Layer &l : m_layers) {
		n += l.meshes.size();
	}
	return n;
}

} // namespace navcore
