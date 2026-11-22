// Written by Claude (claude-opus-5-5), 2026-11-03. History: native/CHANGELOG.md.
// NavServer: the nav library's one public entry point (nav spec section 6). It takes the level as input layers, builds a
// Recast/Detour nav mesh in tiles on worker threads around the places streaming asks for (interests), and answers path searches,
// with links (jumps, drops, placed links).
//
// Registered as an engine singleton, so GDScript writes NavServer.find_path(...); it exists only while the navcore library is
// loaded, so GDScript checks Engine.has_singleton("NavServer") first. Users: world/TerrainNavFeeder and world/BodyNavFeeder feed
// it, NavigationManager finds paths, NavLinkModule places links, CrowdMover hands it to CrowdBatch, diagnostics/NavDebugView draws
// it. Something must call tick() once per physics tick (TerrainNavFeeder does); that's the only place the nav mesh changes and
// queued paths are searched.
// Everything below it lives in namespace navcore and knows nothing about Godot.
#pragma once

#include "ground_domain.h"

#include <algorithm> // std::clamp in tier_radius
#include "input_store.h"
#include "path_queue.h"
#include "tile_manager.h"
#include "worker_pool.h"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <string>
#include <unordered_map>
#include <vector>

namespace godot {

class NavHooks;

class NavServer : public Object {
	GDCLASS(NavServer, Object)

public:
	enum AdapterKind {
		ADAPTER_HEIGHTMAP = 0,
		ADAPTER_MESH = 1,
	};

	NavServer();
	~NavServer() override;

	// ---- setup -----------------------------------------------------------------------------
	// Keys match NavConfig in nav_types.h (cell_size, tile_size_cells, agent_radius, tier_radii...).
	// Changing the config drops every built tile; they rebuild from the stored inputs.
	void configure(const Dictionary &config);
	Dictionary get_config() const;
	void tick(double delta); // once per physics frame

	// ---- input layers (spec 5.3) -----------------------------------------------------------
	int add_input_layer(Object *owner, const Ref<NavHooks> &hooks, int adapter);
	void remove_input_layer(int layer);
	bool submit_heightmap(int layer, Vector2i chunk, const PackedFloat32Array &heights, Vector2i samples,
			float spacing, const PackedByteArray &materials, const AABB &dirty_bounds);
	void release_chunk(int layer, Vector2i chunk);
	// dirty_bounds, as submit_heightmap: only the tiles under it rebuild (empty: the whole mesh's area)
	bool submit_mesh(int layer, int64_t mesh_id, const PackedVector3Array &faces, const Transform3D &xform,
			const String &surface, const AABB &dirty_bounds);
	void remove_mesh(int layer, int64_t mesh_id);
	int surface_index(const String &name); // registers new names, 1..15

	// ---- streaming interest ----------------------------------------------------------------
	int add_interest(const Vector3 &position, float load_radius, float unload_radius, int priority);
	void move_interest(int id, const Vector3 &position);
	void remove_interest(int id);

	// ---- queries ---------------------------------------------------------------------------
	// Queues a search, which tick() runs within query_iterations_per_tick. The answer comes as the path_ready or path_failed
	// signal and is also kept for take_path_result. use_links off (the default) never crosses links.
	int find_path(const Vector3 &from, const Vector3 &to, int tier, bool use_links);
	void cancel_path(int request_id);
	// A queued search's answer, for code that asks rather than listening to path_ready (each NavigationManager would otherwise
	// hear every pawn's paths). Empty while it's still searching (or for an id it doesn't know); then once {ok, points, link_ids,
	// partial, reason}, as find_path_now_result, and it's forgotten. An answer nobody takes is dropped after RESULT_KEEP_TICKS of
	// NavServer's ticks.
	Dictionary take_path_result(int request_id);
	PackedVector3Array find_path_now(const Vector3 &from, const Vector3 &to, int tier); // sync, points only, never crosses links
	Variant closest_point(const Vector3 &p, int tier); // Vector3, or null if no nav nearby
	// find_path_now_result with use_links on.
	Dictionary find_path_now_with_links(const Vector3 &from, const Vector3 &to, int tier);
	// The one sync search that says everything, with or without links: {points, link_ids, partial}. link_ids has one entry per
	// point, not 0 where that point starts a link, which ends at the next point (all 0 without links). partial says the path ends
	// at the closest place it can reach, not at the point. points is empty if there's no way.
	Dictionary find_path_now_result(const Vector3 &from, const Vector3 &to, int tier, bool use_links);

	// For other C++ classes (CrowdBatch): the live ground nav mesh, read-only, and a tier's
	// radius (how far its nav mesh keeps from walls). Not for GDScript.
	const navcore::GroundDomain &ground() const { return m_ground; }
	float tier_radius(int tier) const { return m_cfg.tier_radii[std::clamp(tier, 0, m_cfg.tier_count - 1)]; }

	// ---- links (spec section 10, phase 3) ---------------------------------------------------
	// Placed links, such as a door, a ladder or a jump a designer marked. The tile holding the start rebuilds
	// to include it, on the next ticks. action is the named action a pawn presses at the start, or empty to just walk across.
	int add_link(const Vector3 &start, const Vector3 &end, bool two_way, const StringName &action);
	bool remove_link(int link_id);
	// The action for a link id from a path: a placed link's own, "jump" (auto_link_jump_action) for a jump the build found,
	// and empty for a drop, which is walked off.
	StringName get_link_action(int64_t link_id) const;
	bool is_auto_link(int64_t link_id) const;

	// ---- debug / stats ---------------------------------------------------------------------
	Dictionary get_debug_triangles(const AABB &area);
	// The live links in an area, for drawing and tests: {starts, ends, link_ids, two_way}.
	Dictionary get_debug_links(const AABB &area) const;
	// For tests only: see GroundDomain.
	// REFACTOR: test hooks bound into the shipping class (test code out of shipping code); a test-only subclass or build flag.
	void debug_fail_tile_commits(int count) { m_ground.debug_fail_commits(count); }
	void debug_limit_path_corners(int limit) { m_ground.debug_limit_corners(limit); }
	// For comparing two machines: on, every path search's start and the steps each tick spends on it are logged (PathQueue's
	// debug log); take_debug_path_log() hands them over, five numbers an entry, and empties the log. Off by default.
	void debug_log_path_steps(bool on);
	PackedInt64Array take_debug_path_log();
	Array get_tile_states() const;
	Dictionary get_stats() const;
	bool is_idle() const; // nothing left to build or commit
	// The tiles the last tick committed, in order, each as (x << 32) | z: the landing record (state store spec 13.12).
	PackedInt64Array get_landed_tiles() const;

protected:
	static void _bind_methods();

private:
	void ensure_started();
	void dirty(const navcore::WorldRect &r);

	navcore::NavConfig m_cfg;
	navcore::InputStore m_store;
	navcore::TileManager m_tiles;
	navcore::GroundDomain m_ground;
	navcore::PathQueue m_paths;
	std::vector<int64_t> m_path_log; // PathQueue's debug log, while debug_log_path_steps is on
	bool m_log_paths = false;
	// Answers waiting to be taken (take_path_result), with the tick each came in on.
	struct PathResult {
		Dictionary result;
		uint64_t tick = 0;
	};
	std::unordered_map<int, PathResult> m_path_results;
	static constexpr uint64_t RESULT_KEEP_TICKS = 600;
	navcore::WorkerPool m_pool; // declared after everything a build job uses, so it's destroyed (its workers joined) before them

	std::vector<navcore::Interest> m_interests;
	int m_next_interest = 1;
	std::vector<std::string> m_surface_names; // index = surface id
	std::vector<navcore::WorldRect> m_pending_dirty;
	// Placed links, and the action each one presses.
	std::vector<navcore::LinkDef> m_links;
	std::unordered_map<uint32_t, StringName> m_link_actions;
	uint32_t m_next_link = 1;
	StringName m_auto_jump_action = StringName("jump");
	bool m_started = false;
	uint64_t m_ticks = 0;
	double m_last_tick_ms = 0.0, m_max_tick_ms = 0.0;
};

} // namespace godot

VARIANT_ENUM_CAST(NavServer::AdapterKind);
