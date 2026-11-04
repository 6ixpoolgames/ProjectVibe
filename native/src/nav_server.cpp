// Written by Claude (claude-opus-5-5), 2026-11-03: NavServer, the one public entry point (spec section 6).
#include "nav_server.h"

#include "nav_hooks.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <array>
#include <chrono>

namespace godot {

using navcore::WorldRect;

namespace {
WorldRect rect_from_aabb(const AABB &a) {
	return { float(a.position.x), float(a.position.z), float(a.position.x + a.size.x), float(a.position.z + a.size.z) };
}
} // namespace

NavServer::NavServer() {
	m_surface_names = { "none", "default" }; // ids 0 and 1, see nav_types.h
	m_tiles.reset(m_cfg);
}

NavServer::~NavServer() {
	m_pool.stop(); // join workers before anything they reference goes away
}

void NavServer::ensure_started() {
	if (m_started) {
		return;
	}
	if (!m_ground.ready() && !m_ground.init(m_cfg)) {
		UtilityFunctions::push_error("NavServer: could not initialise the Detour nav mesh");
	}
	m_pool.start(m_cfg.worker_threads);
	m_started = true;
}

// ---- setup ---------------------------------------------------------------------------------------

void NavServer::configure(const Dictionary &config) {
	navcore::NavConfig c = m_cfg;
	auto getf = [&](const char *key, float &v) {
		if (config.has(key)) {
			v = float(config[key]);
		}
	};
	auto geti = [&](const char *key, int &v) {
		if (config.has(key)) {
			v = int(config[key]);
		}
	};
	getf("cell_size", c.cell_size);
	getf("cell_height", c.cell_height);
	geti("tile_size_cells", c.tile_size_cells);
	getf("agent_height", c.agent_height);
	getf("agent_radius", c.agent_radius);
	getf("agent_max_climb", c.agent_max_climb);
	getf("max_slope_deg", c.max_slope_deg);
	getf("world_floor_y", c.world_floor_y);
	getf("world_ceiling_y", c.world_ceiling_y);
	getf("commit_budget_ms", c.commit_budget_ms);
	geti("max_builds_in_flight", c.max_builds_in_flight);
	geti("worker_threads", c.worker_threads);
	geti("query_iterations_per_tick", c.query_iterations_per_tick);
	getf("region_min_size", c.region_min_size);
	getf("region_merge_size", c.region_merge_size);
	getf("edge_max_len", c.edge_max_len);
	getf("edge_max_error", c.edge_max_error);
	getf("detail_sample_dist", c.detail_sample_dist);
	getf("detail_sample_max_error", c.detail_sample_max_error);
	if (config.has("tier_radii")) {
		PackedFloat32Array radii = config["tier_radii"];
		c.tier_count = std::clamp(int(radii.size()), 1, navcore::MAX_TIERS);
		for (int i = 0; i < c.tier_count; ++i) {
			c.tier_radii[i] = radii[i];
		}
		std::sort(c.tier_radii, c.tier_radii + c.tier_count);
	}

	// Keep it sane.
	c.cell_size = std::max(c.cell_size, 0.01f);
	c.cell_height = std::max(c.cell_height, 0.01f);
	c.tile_size_cells = std::clamp(c.tile_size_cells, 16, 256);
	c.max_builds_in_flight = std::max(c.max_builds_in_flight, 1);
	c.tier_radii[0] = c.agent_radius; // tier 0 is by definition the smallest pawn
	const float max_range = (navcore::MAX_SPAN_CELLS - 1) * c.cell_height;
	if (c.world_ceiling_y - c.world_floor_y > max_range) {
		UtilityFunctions::push_warning("NavServer: world height range too big for cell_height; ceiling lowered to ",
				c.world_floor_y + max_range);
		c.world_ceiling_y = c.world_floor_y + max_range;
	}

	// Rebuild everything with the new settings. Inputs are kept, so tiles just build again.
	m_pool.stop();
	m_cfg = c;
	m_tiles.reset(m_cfg);
	m_tiles.resync_after_pool_stop();
	m_paths.clear();
	if (!m_ground.init(m_cfg)) {
		UtilityFunctions::push_error("NavServer: could not initialise the Detour nav mesh");
	}
	m_started = false; // restarts the pool on next tick
}

Dictionary NavServer::get_config() const {
	Dictionary d;
	d["cell_size"] = m_cfg.cell_size;
	d["cell_height"] = m_cfg.cell_height;
	d["tile_size_cells"] = m_cfg.tile_size_cells;
	d["tile_world"] = m_cfg.tile_world();
	d["border_cells"] = m_cfg.border_cells();
	d["agent_height"] = m_cfg.agent_height;
	d["agent_radius"] = m_cfg.agent_radius;
	d["agent_max_climb"] = m_cfg.agent_max_climb;
	d["max_slope_deg"] = m_cfg.max_slope_deg;
	PackedFloat32Array radii;
	for (int i = 0; i < m_cfg.tier_count; ++i) {
		radii.push_back(m_cfg.tier_radii[i]);
	}
	d["tier_radii"] = radii;
	d["world_floor_y"] = m_cfg.world_floor_y;
	d["world_ceiling_y"] = m_cfg.world_ceiling_y;
	d["commit_budget_ms"] = m_cfg.commit_budget_ms;
	d["max_builds_in_flight"] = m_cfg.max_builds_in_flight;
	d["worker_threads"] = m_cfg.worker_threads;
	d["query_iterations_per_tick"] = m_cfg.query_iterations_per_tick;
	return d;
}

void NavServer::tick(double delta) {
	(void)delta;
	ensure_started();
	const auto t0 = std::chrono::steady_clock::now();

	// Phase 1: ingest changes.
	for (const WorldRect &r : m_pending_dirty) {
		m_tiles.mark_dirty(r);
	}
	m_pending_dirty.clear();
	std::vector<navcore::TileKey> changed;
	m_tiles.update_wanted(m_store, m_interests, m_ground, changed);

	// Phase 2: commit finished builds (the only place the nav mesh changes).
	m_tiles.commit_finished(m_ground, m_cfg.commit_budget_ms, changed);

	// Phase 3: start new builds.
	m_tiles.schedule(m_store, m_interests, m_pool);

	// Phase 4: path searches against the now-stable nav mesh.
	std::vector<navcore::PathOutcome> outcomes;
	m_paths.process(m_ground, m_cfg.query_iterations_per_tick, outcomes);

	// Phase 5 (crowd) arrives with agents in phase 3 of the build plan.

	m_last_tick_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
	m_max_tick_ms = std::max(m_max_tick_ms, m_last_tick_ms);
	++m_ticks;

	// Phase 6: tell GDScript. Done last, so handlers may safely call back into NavServer.
	for (const navcore::PathOutcome &o : outcomes) {
		if (o.ok) {
			PackedVector3Array points;
			for (size_t i = 0; i + 2 < o.points.size(); i += 3) {
				points.push_back(Vector3(o.points[i], o.points[i + 1], o.points[i + 2]));
			}
			emit_signal("path_ready", o.id, points, o.partial);
		} else {
			emit_signal("path_failed", o.id, String(o.reason.c_str()));
		}
	}
	if (!changed.empty()) {
		std::sort(changed.begin(), changed.end(), [](const navcore::TileKey &a, const navcore::TileKey &b) {
			return a.z != b.z ? a.z < b.z : a.x < b.x;
		});
		changed.erase(std::unique(changed.begin(), changed.end()), changed.end());
		Array tiles;
		for (const navcore::TileKey &k : changed) {
			tiles.push_back(Vector2i(k.x, k.z));
		}
		emit_signal("tiles_changed", tiles);
	}
}

// ---- input layers --------------------------------------------------------------------------------

int NavServer::add_input_layer(Object *owner, const Ref<NavHooks> &hooks, int adapter) {
	(void)owner; // kept so layers can later be traced back to the generator that made them
	if (hooks.is_null()) {
		UtilityFunctions::push_error("NavServer.add_input_layer: hooks is null");
		return -1;
	}
	if (adapter != ADAPTER_HEIGHTMAP && adapter != ADAPTER_MESH) {
		UtilityFunctions::push_error("NavServer.add_input_layer: unknown adapter ", adapter);
		return -1;
	}
	std::array<uint8_t, 256> surface_map;
	surface_map.fill(navcore::SURFACE_DEFAULT);
	const Dictionary map = hooks->get_surface_map();
	const Array keys = map.keys();
	for (int i = 0; i < keys.size(); ++i) {
		const int material = int(keys[i]);
		if (material >= 0 && material < 256) {
			surface_map[size_t(material)] = uint8_t(surface_index(String(map[keys[i]])));
		}
	}
	const int op = std::clamp(hooks->get_layer_op(), 0, 2);
	return m_store.add_layer(navcore::AdapterKind(adapter), navcore::LayerOp(op), hooks->get_order(), surface_map);
}

void NavServer::remove_input_layer(int layer) {
	WorldRect r;
	bool had_data = false;
	if (m_store.remove_layer(layer, r, had_data) && had_data) {
		dirty(r);
	}
}

bool NavServer::submit_heightmap(int layer, Vector2i chunk, const PackedFloat32Array &heights, Vector2i samples,
		float spacing, const PackedByteArray &materials, const AABB &dirty_bounds) {
	std::vector<float> h(heights.ptr(), heights.ptr() + heights.size());
	WorldRect changed;
	std::string err;
	if (!m_store.submit_heightmap(layer, navcore::ChunkKey{ chunk.x, chunk.y }, samples.x, samples.y, spacing, std::move(h),
				materials.ptr(), size_t(materials.size()), changed, err)) {
		UtilityFunctions::push_error("NavServer.submit_heightmap: ", String(err.c_str()));
		return false;
	}
	const bool has_bounds = dirty_bounds.size.x > 0.0 || dirty_bounds.size.z > 0.0;
	dirty(has_bounds ? rect_from_aabb(dirty_bounds) : changed);
	return true;
}

void NavServer::release_chunk(int layer, Vector2i chunk) {
	WorldRect r;
	if (m_store.release_chunk(layer, navcore::ChunkKey{ chunk.x, chunk.y }, r)) {
		dirty(r);
	}
}

bool NavServer::submit_mesh(int layer, int64_t mesh_id, const PackedVector3Array &faces, const Transform3D &xform,
		const String &surface) {
	if (faces.size() < 3 || faces.size() % 3 != 0) {
		UtilityFunctions::push_error("NavServer.submit_mesh: faces must be a triangle list (Mesh.get_faces())");
		return false;
	}
	std::vector<float> verts;
	std::vector<int> tris;
	verts.reserve(size_t(faces.size()) * 3);
	tris.reserve(size_t(faces.size()));
	for (int i = 0; i < faces.size(); i += 3) {
		// Godot's front faces are clockwise, Recast expects counter-clockwise: swap the last two.
		const Vector3 v[3] = { xform.xform(faces[i]), xform.xform(faces[i + 2]), xform.xform(faces[i + 1]) };
		for (const Vector3 &p : v) {
			tris.push_back(int(verts.size() / 3));
			verts.push_back(float(p.x));
			verts.push_back(float(p.y));
			verts.push_back(float(p.z));
		}
	}
	WorldRect changed;
	std::string err;
	if (!m_store.submit_mesh(layer, mesh_id, std::move(verts), std::move(tris), uint8_t(surface_index(surface)), changed, err)) {
		UtilityFunctions::push_error("NavServer.submit_mesh: ", String(err.c_str()));
		return false;
	}
	dirty(changed);
	return true;
}

void NavServer::remove_mesh(int layer, int64_t mesh_id) {
	WorldRect r;
	if (m_store.remove_mesh(layer, mesh_id, r)) {
		dirty(r);
	}
}

int NavServer::surface_index(const String &name) {
	if (name.is_empty()) {
		return navcore::SURFACE_DEFAULT;
	}
	const std::string n = name.utf8().get_data();
	for (size_t i = 0; i < m_surface_names.size(); ++i) {
		if (m_surface_names[i] == n) {
			return int(i);
		}
	}
	if (m_surface_names.size() >= size_t(navcore::MAX_SURFACES)) {
		UtilityFunctions::push_warning("NavServer: more than 15 surface types; '", name, "' uses the default surface");
		return navcore::SURFACE_DEFAULT;
	}
	m_surface_names.push_back(n);
	return int(m_surface_names.size() - 1);
}

void NavServer::dirty(const WorldRect &r) {
	m_pending_dirty.push_back(r); // applied in tick phase 1
}

// ---- interests -----------------------------------------------------------------------------------

int NavServer::add_interest(const Vector3 &position, float load_radius, float unload_radius, int priority) {
	navcore::Interest in;
	in.id = m_next_interest++;
	in.x = float(position.x);
	in.y = float(position.y);
	in.z = float(position.z);
	in.load_radius = load_radius;
	in.unload_radius = std::max(unload_radius, load_radius);
	in.priority = priority;
	m_interests.push_back(in);
	return in.id;
}

void NavServer::move_interest(int id, const Vector3 &position) {
	for (navcore::Interest &in : m_interests) {
		if (in.id == id) {
			in.x = float(position.x);
			in.y = float(position.y);
			in.z = float(position.z);
			return;
		}
	}
}

void NavServer::remove_interest(int id) {
	m_interests.erase(std::remove_if(m_interests.begin(), m_interests.end(),
							  [id](const navcore::Interest &in) { return in.id == id; }),
			m_interests.end());
}

// ---- queries -------------------------------------------------------------------------------------

int NavServer::find_path(const Vector3 &from, const Vector3 &to, int tier) {
	const float a[3] = { float(from.x), float(from.y), float(from.z) };
	const float b[3] = { float(to.x), float(to.y), float(to.z) };
	return m_paths.push(a, b, tier);
}

void NavServer::cancel_path(int request_id) {
	m_paths.cancel(request_id);
}

PackedVector3Array NavServer::find_path_now(const Vector3 &from, const Vector3 &to, int tier) {
	ensure_started();
	const float a[3] = { float(from.x), float(from.y), float(from.z) };
	const float b[3] = { float(to.x), float(to.y), float(to.z) };
	navcore::PathOutcome o;
	PackedVector3Array points;
	if (m_ground.find_path_now(a, b, tier, o)) {
		for (size_t i = 0; i + 2 < o.points.size(); i += 3) {
			points.push_back(Vector3(o.points[i], o.points[i + 1], o.points[i + 2]));
		}
	}
	return points;
}

Variant NavServer::closest_point(const Vector3 &p, int tier) {
	ensure_started();
	const float a[3] = { float(p.x), float(p.y), float(p.z) };
	float out[3];
	if (!m_ground.closest_point(a, tier, out)) {
		return Variant();
	}
	return Vector3(out[0], out[1], out[2]);
}

// ---- debug / stats -------------------------------------------------------------------------------

Dictionary NavServer::get_debug_triangles(const AABB &area) {
	std::vector<float> verts, colors;
	m_ground.debug_triangles(rect_from_aabb(area), verts, colors);
	PackedVector3Array pv;
	PackedColorArray pc;
	pv.resize(int64_t(verts.size() / 3));
	pc.resize(int64_t(colors.size() / 3));
	for (size_t i = 0; i < verts.size() / 3; ++i) {
		pv.set(int64_t(i), Vector3(verts[i * 3], verts[i * 3 + 1], verts[i * 3 + 2]));
		pc.set(int64_t(i), Color(colors[i * 3], colors[i * 3 + 1], colors[i * 3 + 2]));
	}
	Dictionary d;
	d["vertices"] = pv;
	d["colors"] = pc;
	return d;
}

Array NavServer::get_tile_states() const {
	std::vector<navcore::TileInfo> infos;
	m_tiles.tile_infos(infos);
	Array out;
	for (const navcore::TileInfo &t : infos) {
		Dictionary d;
		d["tile"] = Vector2i(t.key.x, t.key.z);
		d["state"] = String(t.state);
		d["provisional"] = t.provisional;
		d["has_live"] = t.has_live;
		d["polys"] = t.poly_count;
		d["build_ms"] = t.build_ms;
		if (!t.error.empty()) {
			d["error"] = String(t.error.c_str());
		}
		out.push_back(d);
	}
	return out;
}

Dictionary NavServer::get_stats() const {
	navcore::TileStats s;
	m_tiles.stats(s);
	Dictionary d;
	d["tiles"] = s.tiles;
	d["queued"] = s.queued;
	d["building"] = s.building;
	d["ready"] = s.ready;
	d["dirty"] = s.dirty;
	d["failed"] = s.failed;
	d["provisional"] = s.provisional;
	d["results_waiting"] = s.results_waiting;
	d["builds_committed"] = int64_t(s.builds_committed);
	d["builds_stale"] = int64_t(s.builds_stale);
	d["avg_build_ms"] = s.avg_build_ms;
	d["max_build_ms"] = s.max_build_ms;
	d["last_commit_ms"] = s.last_commit_ms;
	d["max_commit_ms"] = s.max_commit_ms;
	d["live_detour_tiles"] = m_ground.tile_count();
	d["layers"] = m_store.layer_count();
	d["chunks"] = int64_t(m_store.chunk_count());
	d["meshes"] = int64_t(m_store.mesh_count());
	d["interests"] = int(m_interests.size());
	d["paths_pending"] = int64_t(m_paths.pending());
	d["worker_threads"] = m_pool.thread_count();
	d["last_tick_ms"] = m_last_tick_ms;
	d["max_tick_ms"] = m_max_tick_ms;
	d["ticks"] = int64_t(m_ticks);
	return d;
}

bool NavServer::is_idle() const {
	return m_pending_dirty.empty() && m_tiles.idle();
}

// ---- bindings ------------------------------------------------------------------------------------

void NavServer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "config"), &NavServer::configure);
	ClassDB::bind_method(D_METHOD("get_config"), &NavServer::get_config);
	ClassDB::bind_method(D_METHOD("tick", "delta"), &NavServer::tick);

	ClassDB::bind_method(D_METHOD("add_input_layer", "owner", "hooks", "adapter"), &NavServer::add_input_layer);
	ClassDB::bind_method(D_METHOD("remove_input_layer", "layer"), &NavServer::remove_input_layer);
	ClassDB::bind_method(D_METHOD("submit_heightmap", "layer", "chunk", "heights", "samples", "spacing", "materials", "dirty_bounds"),
			&NavServer::submit_heightmap, DEFVAL(PackedByteArray()), DEFVAL(AABB()));
	ClassDB::bind_method(D_METHOD("release_chunk", "layer", "chunk"), &NavServer::release_chunk);
	ClassDB::bind_method(D_METHOD("submit_mesh", "layer", "mesh_id", "faces", "xform", "surface"), &NavServer::submit_mesh,
			DEFVAL(String("default")));
	ClassDB::bind_method(D_METHOD("remove_mesh", "layer", "mesh_id"), &NavServer::remove_mesh);
	ClassDB::bind_method(D_METHOD("surface_index", "name"), &NavServer::surface_index);

	ClassDB::bind_method(D_METHOD("add_interest", "position", "load_radius", "unload_radius", "priority"), &NavServer::add_interest,
			DEFVAL(0));
	ClassDB::bind_method(D_METHOD("move_interest", "id", "position"), &NavServer::move_interest);
	ClassDB::bind_method(D_METHOD("remove_interest", "id"), &NavServer::remove_interest);

	ClassDB::bind_method(D_METHOD("find_path", "from", "to", "tier"), &NavServer::find_path, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("cancel_path", "request_id"), &NavServer::cancel_path);
	ClassDB::bind_method(D_METHOD("find_path_now", "from", "to", "tier"), &NavServer::find_path_now, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("closest_point", "point", "tier"), &NavServer::closest_point, DEFVAL(0));

	ClassDB::bind_method(D_METHOD("get_debug_triangles", "area"), &NavServer::get_debug_triangles);
	ClassDB::bind_method(D_METHOD("debug_fail_tile_commits", "count"), &NavServer::debug_fail_tile_commits);
	ClassDB::bind_method(D_METHOD("debug_limit_path_corners", "limit"), &NavServer::debug_limit_path_corners);
	ClassDB::bind_method(D_METHOD("get_tile_states"), &NavServer::get_tile_states);
	ClassDB::bind_method(D_METHOD("get_stats"), &NavServer::get_stats);
	ClassDB::bind_method(D_METHOD("is_idle"), &NavServer::is_idle);

	ADD_SIGNAL(MethodInfo("path_ready", PropertyInfo(Variant::INT, "request_id"),
			PropertyInfo(Variant::PACKED_VECTOR3_ARRAY, "points"), PropertyInfo(Variant::BOOL, "partial")));
	ADD_SIGNAL(MethodInfo("path_failed", PropertyInfo(Variant::INT, "request_id"), PropertyInfo(Variant::STRING, "reason")));
	ADD_SIGNAL(MethodInfo("tiles_changed", PropertyInfo(Variant::ARRAY, "tiles")));

	BIND_ENUM_CONSTANT(ADAPTER_HEIGHTMAP);
	BIND_ENUM_CONSTANT(ADAPTER_MESH);
}

} // namespace godot
