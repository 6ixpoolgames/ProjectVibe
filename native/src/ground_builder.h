// Written by Claude (claude-opus-5-5), 2026-11-03: ground tile build pipeline, input spans -> Detour tile (spec 8.2).
// build_ground_tile is a pure function: it reads only its input and allocates its own result,
// so any number of them can run on worker threads at the same time.
#pragma once

#include "input_store.h"

#include <memory>
#include <string>
#include <vector>

namespace navcore {

struct TileBuildInput {
	TileKey key;
	Version version = 0; // tile version this build was started for
	uint64_t generation = 0; // TileManager reset counter; results from before a reset are thrown away
	NavConfig cfg;
	InputSnapshot snapshot;
	std::vector<LinkDef> placed_links; // Claude 2026-11-08: placed links that start inside this tile, copied when the build starts
};

struct TileBuildResult {
	TileKey key;
	Version version = 0;
	uint64_t generation = 0;
	unsigned char *nav_data = nullptr; // Detour tile data (dtAlloc'd). Ownership moves to dtNavMesh on commit.
	int nav_data_size = 0;
	bool empty = false; // nothing walkable: commit just removes the old tile
	bool provisional = false; // some neighbour data was missing; rebuilt automatically when it arrives
	int poly_count = 0;
	int link_count = 0; // Claude 2026-11-08: placed and found links baked into this tile
	int auto_link_count = 0; // Claude 2026-11-08: of those, how many the build found by itself
	double build_ms = 0.0;
	std::string error;

	TileBuildResult() = default;
	TileBuildResult(const TileBuildResult &) = delete;
	TileBuildResult &operator=(const TileBuildResult &) = delete;
	~TileBuildResult();
};

WorldRect tile_world_rect(const NavConfig &cfg, const TileKey &key);
WorldRect tile_build_rect(const NavConfig &cfg, const TileKey &key); // tile + border

std::unique_ptr<TileBuildResult> build_ground_tile(const TileBuildInput &in);

} // namespace navcore
