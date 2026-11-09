// Written by Claude (claude-opus-5-5), 2026-11-09: line of sight in C++, so it can run on worker threads (scaling spec section 6, tier
// 1 step 4). Physics rays can't safely run off the main thread, so this keeps its own copy of the solid things that block sight and
// tests rays against that instead.
//
// What it holds: every body it's given (StaticBody3D, AnimatableBody3D, RigidBody3D and other CollisionObject3Ds; never areas or
// pawns), as the shapes physics has for them, in world space:
//   - triangle meshes (ConcavePolygonShape3D, which is what TerrainGenerator and the nav test terrain make): the same triangles
//     physics uses, so the terrain blocks sight exactly as it blocks a physics ray;
//   - boxes, spheres, capsules, cylinders and world boundaries, tested exactly;
//   - anything else (a convex hull, a heightmap) as its bounding box, with a warning once per body.
// Each piece keeps its body's collision layer, so a ray only meets pieces on the layers in its mask, as a physics ray would.
//
// Where things are: a grid of cells over the ground (x and z), each listing the pieces that reach into it, so a ray only tests what's
// in the cells it crosses. Pieces too big for that (a floor 400 m across) go in a short list every ray tests.
//
// Keeping up to date, always on the main thread, never while a job reads it:
//   - add_body() and remove_body(), called by SightGeometryFeeder.gd as bodies enter and leave the tree;
//   - mark_dirty(), when a collision shape node is added to or removed from a body;
//   - a shape whose resource changes (set_faces when a terrain chunk is edited, a box resized) marks its body itself;
//   - sync(tick), once a tick: rebuilds every body that's dirty, has moved, or changed layer, and drops freed ones.
// Before it changes anything it calls the change guard, which the job scheduler sets to finish every job still reading it.
//
// What a ray is: from `from` to `to`, blocked if it meets any piece on its mask's layers. As with Godot's physics rays (the
// defaults sight uses), a solid shape the ray starts inside doesn't count, and triangles block from both sides. Physics rounds box
// corners very slightly (Jolt's convex radius), so a ray grazing a corner can disagree; sight_geometry_selftest measures how often.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/plane.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <functional>
#include <limits>
#include <unordered_map>
#include <vector>

namespace godot {

class CollisionObject3D;

class SightGeometry : public RefCounted {
	GDCLASS(SightGeometry, RefCounted)

public:
	// --- For GDScript (SightGeometryFeeder, tests) ---
	void add_body(Object *body); // read at the next sync
	void remove_body(Object *body);
	void mark_dirty(Object *body); // its shapes changed: re-read at the next sync
	// Re-reads what changed since the last sync. Once per tick: a second call with the same tick only rebuilds bodies marked dirty.
	// Returns how many bodies were rebuilt.
	int64_t sync(int64_t tick);
	// The main-thread way to ask, for tests and readouts. Doesn't sync first.
	bool is_blocked(const Vector3 &from, const Vector3 &to, int64_t mask) const;
	void set_cell_size(double size); // metres; rebuilds everything at the next sync. 4 by default
	double get_cell_size() const;
	// bodies, pieces (shapes), triangles, cells, big pieces, and bodies with shapes stood in for by their bounding box
	Dictionary get_stats() const;
	void clear();

	// --- For C++ (AIMemoryStore, AISensingJob): safe on any thread while nothing changes it ---
	bool blocked(const Vector3 &from, const Vector3 &to, uint32_t mask) const;
	void set_change_guard(std::function<void()> guard) { _change_guard = std::move(guard); }
	bool empty() const { return _bodies.empty(); }

protected:
	static void _bind_methods();

private:
	enum Kind : uint8_t { BOX, SPHERE, CAPSULE, CYLINDER, BOUNDARY };
	// A solid shape, tested in its own space: from_world takes world points into it.
	struct Piece {
		Kind kind = BOX;
		uint32_t layer = 0;
		Transform3D from_world;
		Vector3 half_extents; // BOX
		double radius = 0.0; // SPHERE, CAPSULE, CYLINDER
		double half_height = 0.0; // CAPSULE (of the straight part), CYLINDER
		Plane plane; // BOUNDARY, in world space
	};
	struct Triangle {
		Vector3 a, b, c;
		uint32_t layer = 0;
	};
	// What a cell lists: a piece or a triangle of one body.
	struct CellEntry {
		uint32_t body = 0;
		uint32_t index = 0;
		bool triangle = false;
	};
	struct Body {
		uint64_t id = 0; // instance id; 0 for a free slot
		bool dirty = true;
		bool warned = false;
		Transform3D transform;
		uint32_t layer = 0;
		std::vector<Piece> pieces;
		std::vector<Triangle> triangles;
		std::vector<int64_t> cells; // the cells it was put in, so it can be taken out
		bool big = false; // some of it is in the big list
		std::vector<uint64_t> watched_shapes; // shape resources whose changed signal marks it dirty
	};

	void before_change();
	void rebuild(uint32_t slot, CollisionObject3D *body);
	void unplace(uint32_t slot);
	void place(uint32_t slot);
	void place_bounds(uint32_t slot, const AABB &bounds, const CellEntry &ref);
	void on_shape_changed(uint64_t body_id);
	int64_t cell_key(int64_t x, int64_t z) const { return (x << 32) ^ (z & 0xFFFFFFFF); }
	bool hits(const CellEntry &ref, const Vector3 &from, const Vector3 &to, uint32_t mask) const;
	static bool segment_hits_piece(const Piece &piece, const Vector3 &from, const Vector3 &to);
	static bool segment_hits_triangle(const Triangle &t, const Vector3 &from, const Vector3 &to);

	std::vector<Body> _bodies; // by slot; slots are reused
	std::vector<uint32_t> _free_slots;
	std::unordered_map<uint64_t, uint32_t> _slot_of; // instance id -> slot
	// Claude 2026-11-09: each cell also keeps the lowest and highest point of what's in it, and its layers, so a ray passing well
	// above the ground (most do) skips the cell without testing a triangle. Taking a body out leaves them as they were, which only
	// means a ray tests a cell it could have skipped.
	struct Cell {
		std::vector<CellEntry> entries;
		float bottom = std::numeric_limits<float>::infinity();
		float top = -std::numeric_limits<float>::infinity();
		uint32_t layers = 0;
	};
	std::unordered_map<int64_t, Cell> _cells;
	std::vector<CellEntry> _big; // pieces that reach into too many cells, tested by every ray
	// Bodies joining, leaving or changed since the last sync. Kept apart, so a body can join while a job reads the rest.
	std::vector<uint64_t> _pending_add;
	std::vector<uint64_t> _pending_remove;
	std::vector<uint64_t> _pending_dirty;
	double _cell_size = 4.0;
	int64_t _synced_tick = -1;
	std::function<void()> _change_guard;
};

} // namespace godot
