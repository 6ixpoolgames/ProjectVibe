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
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <string>
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

	// ---- debug / stats ---------------------------------------------------------------------
	Dictionary get_debug_triangles(const AABB &area);
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
	bool m_started = false;
	uint64_t m_ticks = 0;
	double m_last_tick_ms = 0.0, m_max_tick_ms = 0.0;
};

} // namespace godot

VARIANT_ENUM_CAST(NavServer::AdapterKind);
