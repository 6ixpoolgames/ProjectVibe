// Written by Claude (claude-opus-5-5), 2026-11-03: input layers and their submitted data (spec 5.3, 5.7).
// Generators submit data on the main thread. The store keeps immutable, ref-counted copies, and a
// build takes an InputSnapshot (references only, no copying) to read on a worker thread.
#pragma once

#include "nav_types.h"

#include <array>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace navcore {

enum class AdapterKind : int { HEIGHTMAP = 0, MESH = 1 };
enum class LayerOp : int { ADD = 0, CARVE = 1, SURFACE = 2 };

using ChunkKey = TileKey;

// One heightmap chunk. Samples sit on a regular grid; neighbouring chunks share their edge row,
// so a chunk of N+1 samples covers N * spacing world units.
struct HeightChunk {
	ChunkKey key;
	int samples_x = 0;
	int samples_z = 0;
	float spacing = 1.0f;
	float origin_x = 0.0f; // world position of sample (0, 0)
	float origin_z = 0.0f;
	std::vector<float> heights; // index = x + z * samples_x
	std::vector<uint8_t> surfaces; // nav surface per sample (already mapped); empty = default surface
	Version version = 0;

	// Height at a world position inside this chunk. Interpolates over the same two triangles per
	// grid square that the test terrain renders ((x,z)-(x+1,z)-(x,z+1) and (x+1,z)-(x+1,z+1)-(x,z+1)),
	// so nav matches the collision mesh exactly instead of approximately.
	float height_at(float wx, float wz) const;
	uint8_t surface_at(float wx, float wz) const;
	WorldRect rect() const;
};

// One imported mesh (level geometry, building, prop), already transformed to world space.
struct MeshItem {
	int64_t id = 0;
	std::vector<float> verts; // x, y, z per vertex, world space
	std::vector<int> tris; // 3 indices per triangle, Recast winding (counter-clockwise from above)
	uint8_t surface = SURFACE_DEFAULT;
	WorldRect bounds;
	Version version = 0;
};

struct LayerInfo {
	int id = -1;
	AdapterKind kind = AdapterKind::HEIGHTMAP;
	LayerOp op = LayerOp::ADD;
	int order = 0;
	std::array<uint8_t, 256> surface_map{}; // generator material id -> nav surface type

	// Heightmap geometry, fixed by the first chunk submitted to the layer.
	int samples_x = 0;
	int samples_z = 0;
	float spacing = 0.0f;
	float chunk_world_x() const { return (samples_x - 1) * spacing; }
	float chunk_world_z() const { return (samples_z - 1) * spacing; }
};

// What one build may read from one layer.
struct LayerSnapshot {
	LayerInfo info;
	std::unordered_map<ChunkKey, std::shared_ptr<const HeightChunk>, TileKeyHash> chunks;
	std::vector<std::shared_ptr<const MeshItem>> meshes;

	const HeightChunk *find_chunk_at(float wx, float wz) const;
};

// What one build may read, all layers, sorted by order.
struct InputSnapshot {
	std::vector<LayerSnapshot> layers;
};

class InputStore {
public:
	int add_layer(AdapterKind kind, LayerOp op, int order, const std::array<uint8_t, 256> &surface_map);
	bool remove_layer(int id, WorldRect &out_dirty, bool &out_had_data);
	bool has_layer(int id) const;
	const LayerInfo *layer_info(int id) const;

	// All of these return false (and fill err) on bad input. out_dirty = world area that changed.
	bool submit_heightmap(int layer, ChunkKey chunk, int samples_x, int samples_z, float spacing,
			std::vector<float> &&heights, const uint8_t *materials, size_t material_count,
			WorldRect &out_dirty, std::string &err);
	bool release_chunk(int layer, ChunkKey chunk, WorldRect &out_dirty);
	bool submit_mesh(int layer, int64_t id, std::vector<float> &&verts, std::vector<int> &&tris,
			uint8_t surface, WorldRect &out_dirty, std::string &err);
	bool remove_mesh(int layer, int64_t id, WorldRect &out_dirty);

	// Does any ADD layer have data in this area? (A tile with only CARVE/SURFACE data has nothing to walk on.)
	bool has_walkable_source_in(const WorldRect &r) const;

	// Collect references to everything overlapping r. Main thread only.
	void snapshot(const WorldRect &r, InputSnapshot &out) const;

	int layer_count() const { return int(m_layers.size()); }
	size_t chunk_count() const;
	size_t mesh_count() const;

private:
	struct Layer {
		LayerInfo info;
		std::unordered_map<ChunkKey, std::shared_ptr<const HeightChunk>, TileKeyHash> chunks;
		std::unordered_map<int64_t, std::shared_ptr<const MeshItem>> meshes;
	};

	Layer *find(int id);
	const Layer *find(int id) const;

	std::vector<Layer> m_layers; // kept sorted by order (then id)
	int m_next_id = 1;
	Version m_next_version = 1;
};

} // namespace navcore
