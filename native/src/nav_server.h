// Written by Claude (claude-opus-5-5), 2026-11-03: NavServer, the one public entry point (spec section 6).
// Registered as an engine singleton, so GDScript just writes NavServer.find_path(...).
// Everything below it lives in namespace navcore and knows nothing about Godot.
#pragma once

#include "ground_domain.h"
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
	bool submit_mesh(int layer, int64_t mesh_id, const PackedVector3Array &faces, const Transform3D &xform,
			const String &surface);
	void remove_mesh(int layer, int64_t mesh_id);
	int surface_index(const String &name); // registers new names, 1..15

	// ---- streaming interest ----------------------------------------------------------------
	int add_interest(const Vector3 &position, float load_radius, float unload_radius, int priority);
	void move_interest(int id, const Vector3 &position);
	void remove_interest(int id);

	// ---- queries ---------------------------------------------------------------------------
	int find_path(const Vector3 &from, const Vector3 &to, int tier); // async: path_ready / path_failed
	void cancel_path(int request_id);
	PackedVector3Array find_path_now(const Vector3 &from, const Vector3 &to, int tier); // sync, for tests/tools
	Variant closest_point(const Vector3 &p, int tier); // Vector3, or null if no nav nearby
	// Claude 2026-11-08: like find_path_now, but the path may cross links. Returns {points, link_ids, partial}: link_ids has one
	// entry per point, not 0 where that point starts a link, which ends at the next point. points is empty if there's no way.
	// find_path_now and find_path never cross links, so code written before links existed gets the same paths as before.
	Dictionary find_path_now_with_links(const Vector3 &from, const Vector3 &to, int tier);

	// ---- links (spec section 10, phase 3) ---------------------------------------------------
	// Claude 2026-11-08: placed links, such as a door, a ladder or a jump a designer marked. The tile holding the start rebuilds
	// to include it, on the next ticks. action is the named action a pawn presses at the start, or empty to just walk across.
	int add_link(const Vector3 &start, const Vector3 &end, bool two_way, const StringName &action);
	bool remove_link(int link_id);
	// The action for a link id from a path: a placed link's own, "jump" (auto_link_jump_action) for a jump the build found,
	// and empty for a drop, which is walked off.
	StringName get_link_action(int64_t link_id) const;
	bool is_auto_link(int64_t link_id) const;

	// ---- debug / stats ---------------------------------------------------------------------
	Dictionary get_debug_triangles(const AABB &area);
	// Claude 2026-11-08: the live links in an area, for drawing and tests: {starts, ends, link_ids, two_way}.
	Dictionary get_debug_links(const AABB &area) const;
	// Claude 2026-11-05: for tests only: see GroundDomain.
	void debug_fail_tile_commits(int count) { m_ground.debug_fail_commits(count); }
	void debug_limit_path_corners(int limit) { m_ground.debug_limit_corners(limit); }
	Array get_tile_states() const;
	Dictionary get_stats() const;
	bool is_idle() const; // nothing left to build or commit

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
	navcore::WorkerPool m_pool; // declared last: destroyed first, so no job outlives what it uses

	std::vector<navcore::Interest> m_interests;
	int m_next_interest = 1;
	std::vector<std::string> m_surface_names; // index = surface id
	std::vector<navcore::WorldRect> m_pending_dirty;
	// Claude 2026-11-08: placed links, and the action each one presses.
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
