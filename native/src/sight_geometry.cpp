// Written by Claude (claude-opus-5-5), 2026-11-09. History: native/CHANGELOG.md.
// SightGeometry: line of sight (and the ground) in C++. Described in sight_geometry.h.
#include "sight_geometry.h"

#include <godot_cpp/classes/animatable_body3d.hpp>
#include <godot_cpp/classes/area3d.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/classes/capsule_shape3d.hpp>
#include <godot_cpp/classes/collision_object3d.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/classes/cylinder_shape3d.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/classes/sphere_shape3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/classes/world_boundary_shape3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
// A piece reaching into more cells than this goes in the list every ray tests, instead of filling the grid.
constexpr int64_t BIG_CELLS = 64;

// Points in double precision for the tests, so grazing rays come out the same way physics decides them as often as possible.
struct D3 {
	double x, y, z;
	D3(const Vector3 &v) :
			x(v.x), y(v.y), z(v.z) {}
	D3(double a, double b, double c) :
			x(a), y(b), z(c) {}
	D3 operator-(const D3 &o) const { return D3(x - o.x, y - o.y, z - o.z); }
	D3 operator+(const D3 &o) const { return D3(x + o.x, y + o.y, z + o.z); }
	D3 operator*(double s) const { return D3(x * s, y * s, z * s); }
	double dot(const D3 &o) const { return x * o.x + y * o.y + z * o.z; }
	D3 cross(const D3 &o) const { return D3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x); }
};

// The squared distance between segments p1-q1 and p2-q2 (Ericson, Real-Time Collision Detection, 5.1.9).
double segment_distance_squared(const D3 &p1, const D3 &q1, const D3 &p2, const D3 &q2) {
	const D3 d1 = q1 - p1;
	const D3 d2 = q2 - p2;
	const D3 r = p1 - p2;
	const double a = d1.dot(d1);
	const double e = d2.dot(d2);
	const double f = d2.dot(r);
	constexpr double EPS = 1e-12;
	double s = 0.0;
	double t = 0.0;
	if (a <= EPS && e <= EPS) {
		return r.dot(r);
	}
	if (a <= EPS) {
		t = std::clamp(f / e, 0.0, 1.0);
	} else {
		const double c = d1.dot(r);
		if (e <= EPS) {
			s = std::clamp(-c / a, 0.0, 1.0);
		} else {
			const double b = d1.dot(d2);
			const double denom = a * e - b * b;
			s = denom > EPS ? std::clamp((b * f - c * e) / denom, 0.0, 1.0) : 0.0;
			t = (b * s + f) / e;
			if (t < 0.0) {
				t = 0.0;
				s = std::clamp(-c / a, 0.0, 1.0);
			} else if (t > 1.0) {
				t = 1.0;
				s = std::clamp((b - c) / a, 0.0, 1.0);
			}
		}
	}
	const D3 between = (p1 + d1 * s) - (p2 + d2 * t);
	return between.dot(between);
}

// The squared distance from point p to segment a-b.
double point_segment_distance_squared(const D3 &p, const D3 &a, const D3 &b) {
	const D3 ab = b - a;
	const double length = ab.dot(ab);
	const double t = length > 1e-12 ? std::clamp((p - a).dot(ab) / length, 0.0, 1.0) : 0.0;
	const D3 closest = a + ab * t;
	const D3 between = p - closest;
	return between.dot(between);
}
} // namespace

// --- For GDScript ---

void SightGeometry::add_body(Object *object) {
	CollisionObject3D *body = Object::cast_to<CollisionObject3D>(object);
	if (body == nullptr || Object::cast_to<Area3D>(object) != nullptr) {
		return; // areas don't stop rays (sight's rays don't collide with areas)
	}
	const uint64_t id = body->get_instance_id();
	if (_slot_of.count(id) > 0) {
		mark_dirty(object);
		return;
	}
	// Nothing changes here: a job may be reading. The body joins at the next sync.
	_pending_add.push_back(id);
}

void SightGeometry::remove_body(Object *object) {
	if (object != nullptr) {
		_pending_remove.push_back(object->get_instance_id());
	}
}

void SightGeometry::mark_dirty(Object *object) {
	if (object != nullptr) {
		_pending_dirty.push_back(object->get_instance_id());
	}
}

// A shape changed; every body using it is read again at the next sync.
void SightGeometry::on_shape_changed(uint64_t shape_id) {
	auto found = _shape_watchers.find(shape_id);
	if (found != _shape_watchers.end()) {
		_pending_dirty.insert(_pending_dirty.end(), found->second.begin(), found->second.end());
	}
}

// A body leaving stops being marked by its shapes. The connection itself stays (it's one
// per shape, and a shape nobody watches just marks nothing); it's dropped with the shape or this geometry.
void SightGeometry::unwatch_shapes(const Body &body) {
	for (uint64_t shape_id : body.watched_shapes) {
		auto found = _shape_watchers.find(shape_id);
		if (found == _shape_watchers.end()) {
			continue;
		}
		std::vector<uint64_t> &watchers = found->second;
		watchers.erase(std::remove(watchers.begin(), watchers.end(), body.id), watchers.end());
		if (watchers.empty()) {
			_shape_watchers.erase(found);
		}
	}
}

int64_t SightGeometry::sync(int64_t tick) {
	const bool new_tick = tick != _synced_tick;
	if (!new_tick && _pending_add.empty() && _pending_remove.empty() && _pending_dirty.empty()) {
		return 0;
	}
	_synced_tick = tick;
	bool guarded = false;
	auto change = [&]() {
		if (!guarded) {
			before_change();
			guarded = true;
		}
	};
	int64_t rebuilt = 0;
	// Leaving first, so a body that left and came back is read fresh.
	for (uint64_t id : _pending_remove) {
		auto found = _slot_of.find(id);
		if (found == _slot_of.end()) {
			continue;
		}
		change();
		const uint32_t slot = found->second;
		unplace(slot);
		unwatch_shapes(_bodies[slot]);
		_bodies[slot] = Body();
		_free_slots.push_back(slot);
		_slot_of.erase(found);
	}
	_pending_remove.clear();
	for (uint64_t id : _pending_add) {
		if (_slot_of.count(id) > 0) {
			continue;
		}
		change();
		uint32_t slot;
		if (!_free_slots.empty()) {
			slot = _free_slots.back();
			_free_slots.pop_back();
		} else {
			slot = uint32_t(_bodies.size());
			_bodies.emplace_back();
		}
		_bodies[slot] = Body();
		_bodies[slot].id = id;
		_bodies[slot].dirty = true;
		_slot_of[id] = slot;
	}
	_pending_add.clear();
	for (uint64_t id : _pending_dirty) {
		auto found = _slot_of.find(id);
		if (found != _slot_of.end()) {
			_bodies[found->second].dirty = true;
		}
	}
	_pending_dirty.clear();
	for (uint32_t slot = 0; slot < _bodies.size(); ++slot) {
		Body &body = _bodies[slot];
		if (body.id == 0) {
			continue;
		}
		CollisionObject3D *node = Object::cast_to<CollisionObject3D>(ObjectDB::get_instance(body.id));
		if (node == nullptr || !node->is_inside_tree()) {
			change(); // freed, or left the tree without telling us
			unplace(slot);
			unwatch_shapes(body);
			_slot_of.erase(body.id);
			body = Body();
			_free_slots.push_back(slot);
			continue;
		}
		// A new tick checks every body for a move or a new layer; within the same tick, only the ones marked.
		// A static body only every FIXED_CHECK_TICKS ticks, each on its own tick of them
		// (by its slot), so the checks are spread out instead of all landing on one tick (% is the remainder).
		const bool due = new_tick && (!body.fixed || (uint64_t(tick) + slot) % FIXED_CHECK_TICKS == 0);
		const bool moved = due && (node->get_global_transform() != body.transform || node->get_collision_layer() != body.layer);
		if (body.dirty || moved) {
			change();
			rebuild(slot, node);
			++rebuilt;
		}
	}
	return rebuilt;
}

bool SightGeometry::is_blocked(const Vector3 &from, const Vector3 &to, int64_t mask) const {
	return blocked(from, to, uint32_t(mask));
}

void SightGeometry::set_cell_size(double size) {
	before_change();
	_cell_size = std::max(size, 0.5);
	for (uint32_t slot = 0; slot < _bodies.size(); ++slot) {
		if (_bodies[slot].id != 0) {
			unplace(slot);
			_bodies[slot].dirty = true;
		}
	}
	_cells.clear();
	_big.clear();
	_synced_tick = -1;
}

double SightGeometry::get_cell_size() const {
	return _cell_size;
}

Dictionary SightGeometry::get_stats() const {
	int64_t bodies = 0;
	int64_t pieces = 0;
	int64_t triangles = 0;
	int64_t stand_ins = 0;
	for (const Body &body : _bodies) {
		if (body.id == 0) {
			continue;
		}
		++bodies;
		pieces += int64_t(body.pieces.size());
		triangles += int64_t(body.triangles.size());
		stand_ins += body.warned ? 1 : 0;
	}
	Dictionary stats;
	stats["bodies"] = bodies;
	stats["pieces"] = pieces;
	stats["triangles"] = triangles;
	stats["cells"] = int64_t(_cells.size());
	stats["big"] = int64_t(_big.size());
	stats["bounding_box_stand_ins"] = stand_ins;
	return stats;
}

void SightGeometry::clear() {
	before_change();
	_bodies.clear();
	_free_slots.clear();
	_slot_of.clear();
	_cells.clear();
	_big.clear();
	_pending_add.clear();
	_pending_remove.clear();
	_pending_dirty.clear();
	_shape_watchers.clear();
	_synced_tick = -1;
}

// --- Building ---

void SightGeometry::before_change() {
	_change_guard.before_change(); // waits for every reader (change_guard.h)
}

void SightGeometry::rebuild(uint32_t slot, CollisionObject3D *node) {
	Body &body = _bodies[slot];
	unplace(slot);
	body.pieces.clear();
	body.triangles.clear();
	body.dirty = false;
	body.transform = node->get_global_transform();
	body.layer = node->get_collision_layer();
	// AnimatableBody3D extends StaticBody3D, but it's made to move, so it's checked every tick.
	body.fixed = Object::cast_to<StaticBody3D>(node) != nullptr && Object::cast_to<AnimatableBody3D>(node) == nullptr;
	const PackedInt32Array owners = node->get_shape_owners();
	for (int64_t o = 0; o < owners.size(); ++o) {
		const uint32_t owner = uint32_t(owners[o]);
		if (node->is_shape_owner_disabled(owner)) {
			continue;
		}
		const Transform3D owner_transform = body.transform * node->shape_owner_get_transform(owner);
		const int32_t count = node->shape_owner_get_shape_count(owner);
		for (int32_t s = 0; s < count; ++s) {
			Ref<Shape3D> shape = node->shape_owner_get_shape(owner, s);
			if (shape.is_null()) {
				continue;
			}
			// A shape whose resource changes (a terrain chunk's triangles after an edit, a box resized) marks this body.
			// Through _shape_watchers, with one connection per shape (see the header).
			const uint64_t shape_id = shape->get_instance_id();
			if (std::find(body.watched_shapes.begin(), body.watched_shapes.end(), shape_id) == body.watched_shapes.end()) {
				body.watched_shapes.push_back(shape_id);
				_shape_watchers[shape_id].push_back(body.id);
				const Callable on_changed = callable_mp(this, &SightGeometry::on_shape_changed).bind(shape_id);
				if (!shape->is_connected("changed", on_changed)) {
					shape->connect("changed", on_changed);
				}
			}
			Piece piece;
			piece.layer = body.layer;
			piece.from_world = owner_transform.affine_inverse();
			if (BoxShape3D *box = Object::cast_to<BoxShape3D>(shape.ptr())) {
				piece.kind = BOX;
				piece.half_extents = box->get_size() * 0.5;
			} else if (SphereShape3D *sphere = Object::cast_to<SphereShape3D>(shape.ptr())) {
				piece.kind = SPHERE;
				piece.radius = sphere->get_radius();
			} else if (CapsuleShape3D *capsule = Object::cast_to<CapsuleShape3D>(shape.ptr())) {
				piece.kind = CAPSULE; // Godot's capsule height counts the round ends
				piece.radius = capsule->get_radius();
				piece.half_height = std::max(capsule->get_height() * 0.5 - capsule->get_radius(), 0.0);
			} else if (CylinderShape3D *cylinder = Object::cast_to<CylinderShape3D>(shape.ptr())) {
				piece.kind = CYLINDER;
				piece.radius = cylinder->get_radius();
				piece.half_height = cylinder->get_height() * 0.5;
			} else if (WorldBoundaryShape3D *boundary = Object::cast_to<WorldBoundaryShape3D>(shape.ptr())) {
				piece.kind = BOUNDARY;
				piece.plane = owner_transform.xform(boundary->get_plane());
			} else if (ConcavePolygonShape3D *mesh = Object::cast_to<ConcavePolygonShape3D>(shape.ptr())) {
				const PackedVector3Array faces = mesh->get_faces();
				for (int64_t f = 0; f + 2 < faces.size(); f += 3) {
					Triangle t;
					t.a = owner_transform.xform(faces[f]);
					t.b = owner_transform.xform(faces[f + 1]);
					t.c = owner_transform.xform(faces[f + 2]);
					t.layer = body.layer;
					body.triangles.push_back(t);
				}
				continue;
			} else {
				// Anything else stands in as its bounding box (scaling spec section 6), with a warning once per body.
				Ref<ArrayMesh> debug_mesh = shape->get_debug_mesh();
				const AABB bounds = debug_mesh.is_valid() ? debug_mesh->get_aabb() : AABB();
				if (!body.warned) {
					body.warned = true;
					UtilityFunctions::push_warning("SightGeometry: ", node->get_name(), " has a ", shape->get_class(),
							", which line of sight treats as its bounding box. Boxes, spheres, capsules, cylinders and triangle meshes are exact.");
				}
				piece.kind = BOX;
				piece.half_extents = bounds.size * 0.5;
				piece.from_world = (owner_transform * Transform3D(Basis(), bounds.get_center())).affine_inverse();
			}
			body.pieces.push_back(piece);
		}
	}
	place(slot);
}

void SightGeometry::unplace(uint32_t slot) {
	Body &body = _bodies[slot];
	for (int64_t key : body.cells) {
		auto cell = _cells.find(key);
		if (cell == _cells.end()) {
			continue;
		}
		std::vector<CellEntry> &refs = cell->second.entries;
		refs.erase(std::remove_if(refs.begin(), refs.end(), [slot](const CellEntry &r) { return r.body == slot; }), refs.end());
		if (refs.empty()) {
			_cells.erase(cell);
		}
	}
	body.cells.clear();
	if (body.big) {
		_big.erase(std::remove_if(_big.begin(), _big.end(), [slot](const CellEntry &r) { return r.body == slot; }), _big.end());
		body.big = false;
	}
}

void SightGeometry::place(uint32_t slot) {
	Body &body = _bodies[slot];
	for (uint32_t i = 0; i < body.pieces.size(); ++i) {
		const Piece &piece = body.pieces[i];
		CellEntry ref{ slot, i, false };
		if (piece.kind == BOUNDARY) {
			_big.push_back(ref); // endless
			body.big = true;
			continue;
		}
		Vector3 reach;
		switch (piece.kind) {
			case BOX:
				reach = piece.half_extents;
				break;
			case SPHERE:
				reach = Vector3(piece.radius, piece.radius, piece.radius);
				break;
			case CAPSULE:
				reach = Vector3(piece.radius, piece.half_height + piece.radius, piece.radius);
				break;
			default: // CYLINDER
				reach = Vector3(piece.radius, piece.half_height, piece.radius);
				break;
		}
		const AABB local(-reach, reach * 2.0);
		place_bounds(slot, piece.from_world.affine_inverse().xform(local), ref);
	}
	for (uint32_t i = 0; i < body.triangles.size(); ++i) {
		const Triangle &t = body.triangles[i];
		AABB bounds(t.a, Vector3());
		bounds.expand_to(t.b);
		bounds.expand_to(t.c);
		place_bounds(slot, bounds, CellEntry{ slot, i, true });
	}
	std::sort(body.cells.begin(), body.cells.end());
	body.cells.erase(std::unique(body.cells.begin(), body.cells.end()), body.cells.end());
}

void SightGeometry::place_bounds(uint32_t slot, const AABB &bounds, const CellEntry &ref) {
	const int64_t x0 = int64_t(std::floor(bounds.position.x / _cell_size));
	const int64_t x1 = int64_t(std::floor((bounds.position.x + bounds.size.x) / _cell_size));
	const int64_t z0 = int64_t(std::floor(bounds.position.z / _cell_size));
	const int64_t z1 = int64_t(std::floor((bounds.position.z + bounds.size.z) / _cell_size));
	if ((x1 - x0 + 1) * (z1 - z0 + 1) > BIG_CELLS) {
		_big.push_back(ref);
		_bodies[slot].big = true;
		return;
	}
	for (int64_t x = x0; x <= x1; ++x) {
		for (int64_t z = z0; z <= z1; ++z) {
			const int64_t key = cell_key(x, z);
			Cell &cell = _cells[key];
			cell.entries.push_back(ref);
			cell.bottom = std::min(cell.bottom, float(bounds.position.y));
			cell.top = std::max(cell.top, float(bounds.position.y + bounds.size.y));
			cell.layers |= _bodies[slot].layer;
			_bodies[slot].cells.push_back(key);
		}
	}
}

// --- Rays ---

bool SightGeometry::blocked(const Vector3 &from, const Vector3 &to, uint32_t mask) const {
	for (const CellEntry &ref : _big) {
		if (hits(ref, from, to, mask)) {
			return true;
		}
	}
	if (_cells.empty()) {
		return false;
	}
	// Walk the cells the ray crosses, seen from above, in order (a 2D grid walk, Amanatides and Woo).
	const double x = from.x / _cell_size;
	const double z = from.z / _cell_size;
	const double dx = to.x / _cell_size - x;
	const double dz = to.z / _cell_size - z;
	int64_t cx = int64_t(std::floor(x));
	int64_t cz = int64_t(std::floor(z));
	const int64_t end_x = int64_t(std::floor(to.x / _cell_size));
	const int64_t end_z = int64_t(std::floor(to.z / _cell_size));
	const int64_t step_x = dx > 0.0 ? 1 : -1;
	const int64_t step_z = dz > 0.0 ? 1 : -1;
	const double inf = std::numeric_limits<double>::infinity();
	double next_x = dx != 0.0 ? ((double(cx) + (dx > 0.0 ? 1.0 : 0.0)) - x) / dx : inf;
	double next_z = dz != 0.0 ? ((double(cz) + (dz > 0.0 ? 1.0 : 0.0)) - z) / dz : inf;
	const double each_x = dx != 0.0 ? std::abs(1.0 / dx) : inf;
	const double each_z = dz != 0.0 ? std::abs(1.0 / dz) : inf;
	int64_t steps = std::abs(end_x - cx) + std::abs(end_z - cz);
	const double dy = double(to.y) - double(from.y);
	double t_in = 0.0; // where the ray enters this cell, as a share of its length
	for (;;) {
		const double t_out = std::min(std::min(next_x, next_z), 1.0);
		auto cell = _cells.find(cell_key(cx, cz));
		if (cell != _cells.end() && (cell->second.layers & mask) != 0) {
			// Skip the cell if the ray is above or below everything in it while it crosses.
			const double y_in = from.y + dy * t_in;
			const double y_out = from.y + dy * t_out;
			if (std::min(y_in, y_out) <= cell->second.top && std::max(y_in, y_out) >= cell->second.bottom) {
				for (const CellEntry &ref : cell->second.entries) {
					if (hits(ref, from, to, mask)) {
						return true;
					}
				}
			}
		}
		if (steps-- <= 0) {
			return false;
		}
		t_in = t_out;
		if (next_x < next_z) {
			cx += step_x;
			next_x += each_x;
		} else {
			cz += step_z;
			next_z += each_z;
		}
	}
}

bool SightGeometry::hits(const CellEntry &ref, const Vector3 &from, const Vector3 &to, uint32_t mask) const {
	const Body &body = _bodies[ref.body];
	if (ref.triangle) {
		const Triangle &t = body.triangles[ref.index];
		return (t.layer & mask) != 0 && segment_hits_triangle(t, from, to);
	}
	const Piece &piece = body.pieces[ref.index];
	return (piece.layer & mask) != 0 && segment_hits_piece(piece, from, to);
}

// --- The ground (for CrowdBatch) ---

int SightGeometry::ground_at(double x, double z, double top, double bottom, uint32_t mask, double &height, Vector3 &normal) const {
	// Braces, not brackets: "Vector3 from(real_t(x), ...)" reads to C++ as a function declaration.
	const Vector3 from{ real_t(x), real_t(top), real_t(z) };
	const Vector3 to{ real_t(x), real_t(bottom), real_t(z) };
	double nearest = 2.0; // as a share of the drop; anything over 1 means nothing yet
	bool unsure = false;
	auto test = [&](const CellEntry &ref) {
		Vector3 hit_normal;
		const double t = ground_hit(ref, from, to, mask, hit_normal, unsure);
		if (t >= 0.0 && t < nearest) {
			nearest = t;
			normal = hit_normal;
		}
	};
	for (const CellEntry &ref : _big) {
		test(ref);
	}
	// A straight-down ray stays in one cell.
	auto cell = _cells.find(cell_key(int64_t(std::floor(x / _cell_size)), int64_t(std::floor(z / _cell_size))));
	if (cell != _cells.end() && (cell->second.layers & mask) != 0 && cell->second.top >= bottom && cell->second.bottom <= top) {
		for (const CellEntry &ref : cell->second.entries) {
			test(ref);
		}
	}
	if (unsure) {
		return -1;
	}
	if (nearest > 1.0) {
		return 0;
	}
	height = top + (bottom - top) * nearest;
	if (normal.y < 0.0) {
		normal = -normal; // a triangle seen from below: the ground faces up
	}
	return 1;
}

Dictionary SightGeometry::find_ground(const Vector3 &point, double top, double bottom, int64_t mask) const {
	double height = 0.0;
	Vector3 normal;
	const int found = ground_at(point.x, point.z, top, bottom, uint32_t(mask), height, normal);
	Dictionary result;
	result["found"] = found;
	result["height"] = height;
	result["normal"] = normal;
	return result;
}

double SightGeometry::ground_hit(const CellEntry &ref, const Vector3 &from, const Vector3 &to, uint32_t mask, Vector3 &normal,
		bool &unsure) const {
	const Body &body = _bodies[ref.body];
	if (ref.triangle) {
		const Triangle &t = body.triangles[ref.index];
		if ((t.layer & mask) == 0) {
			return -1.0;
		}
		// As segment_hits_triangle, keeping how far along it hits.
		const D3 a(t.a);
		const D3 e1 = D3(t.b) - a;
		const D3 e2 = D3(t.c) - a;
		const D3 origin(from);
		const D3 direction = D3(to) - origin;
		const D3 p = direction.cross(e2);
		const double det = e1.dot(p);
		if (std::abs(det) < 1e-12) {
			return -1.0;
		}
		const double inverse = 1.0 / det;
		const D3 s = origin - a;
		const double u = s.dot(p) * inverse;
		if (u < 0.0 || u > 1.0) {
			return -1.0;
		}
		const D3 q = s.cross(e1);
		const double v = direction.dot(q) * inverse;
		if (v < 0.0 || u + v > 1.0) {
			return -1.0;
		}
		const double along = e2.dot(q) * inverse;
		if (along < 0.0 || along > 1.0) {
			return -1.0;
		}
		const D3 n = e1.cross(e2);
		normal = Vector3(real_t(n.x), real_t(n.y), real_t(n.z)).normalized();
		return along;
	}
	const Piece &piece = body.pieces[ref.index];
	if ((piece.layer & mask) == 0) {
		return -1.0;
	}
	if (piece.kind == BOUNDARY) {
		const double start = piece.plane.distance_to(from);
		const double end = piece.plane.distance_to(to);
		if (start < 0.0 || end > 0.0 || start == end) {
			return -1.0; // starts inside (behind it), or never reaches it
		}
		normal = piece.plane.normal;
		return start / (start - end);
	}
	if (piece.kind == CAPSULE || piece.kind == CYLINDER) {
		if (segment_hits_piece(piece, from, to)) {
			unsure = true; // in the way, but where exactly isn't worked out here
		}
		return -1.0;
	}
	// A normal in the shape's own space, turned into world space by the transpose of from_world's basis, which is right for normals
	// even when the shape is scaled.
	const Basis to_world_normal = piece.from_world.basis.transposed();
	const D3 p0(piece.from_world.xform(from));
	const D3 p1(piece.from_world.xform(to));
	const D3 d = p1 - p0;
	if (piece.kind == BOX) {
		const double e[3] = { piece.half_extents.x, piece.half_extents.y, piece.half_extents.z };
		const double start[3] = { p0.x, p0.y, p0.z };
		const double along[3] = { d.x, d.y, d.z };
		if (std::abs(p0.x) < e[0] && std::abs(p0.y) < e[1] && std::abs(p0.z) < e[2]) {
			return -1.0; // starts inside
		}
		double t0 = 0.0;
		double t1 = 1.0;
		int entered = -1; // the axis whose face it comes in through
		double entered_sign = 0.0;
		for (int axis = 0; axis < 3; ++axis) {
			if (std::abs(along[axis]) < 1e-12) {
				if (std::abs(start[axis]) > e[axis]) {
					return -1.0;
				}
				continue;
			}
			double ta = (-e[axis] - start[axis]) / along[axis];
			double tb = (e[axis] - start[axis]) / along[axis];
			const double sign = along[axis] > 0.0 ? -1.0 : 1.0; // it comes in through the face turned back toward it
			if (ta > tb) {
				std::swap(ta, tb);
			}
			if (ta > t0) {
				t0 = ta;
				entered = axis;
				entered_sign = sign;
			}
			t1 = std::min(t1, tb);
			if (t0 > t1) {
				return -1.0;
			}
		}
		Vector3 local;
		if (entered >= 0) {
			local[entered] = real_t(entered_sign);
		} else {
			local = Vector3(0, 1, 0); // touching at its very start: call it the top
		}
		normal = to_world_normal.xform(local).normalized();
		return t0;
	}
	if (piece.kind == SPHERE) {
		const double r2 = piece.radius * piece.radius;
		const double c = p0.dot(p0) - r2;
		if (c < 0.0) {
			return -1.0; // starts inside
		}
		const double a = d.dot(d);
		const double b = p0.dot(d);
		const double discriminant = b * b - a * c;
		if (a < 1e-12 || discriminant < 0.0) {
			return -1.0;
		}
		const double t = (-b - std::sqrt(discriminant)) / a;
		if (t < 0.0 || t > 1.0) {
			return -1.0;
		}
		const D3 at = p0 + d * t;
		normal = to_world_normal.xform(Vector3(real_t(at.x), real_t(at.y), real_t(at.z))).normalized();
		return t;
	}
	return -1.0;
}

// Both sides count, as Godot's rays hit the back faces of triangle meshes by default.
bool SightGeometry::segment_hits_triangle(const Triangle &t, const Vector3 &from, const Vector3 &to) {
	const D3 a(t.a);
	const D3 e1 = D3(t.b) - a;
	const D3 e2 = D3(t.c) - a;
	const D3 origin(from);
	const D3 direction = D3(to) - origin;
	const D3 p = direction.cross(e2);
	const double det = e1.dot(p);
	if (std::abs(det) < 1e-12) {
		return false; // the ray runs along the triangle's plane
	}
	const double inverse = 1.0 / det;
	const D3 s = origin - a;
	const double u = s.dot(p) * inverse;
	if (u < 0.0 || u > 1.0) {
		return false;
	}
	const D3 q = s.cross(e1);
	const double v = direction.dot(q) * inverse;
	if (v < 0.0 || u + v > 1.0) {
		return false;
	}
	const double along = e2.dot(q) * inverse;
	return along >= 0.0 && along <= 1.0;
}

// Solid shapes, in their own space. A ray that starts inside one isn't blocked by it, as with Godot's rays (hit_from_inside off).
bool SightGeometry::segment_hits_piece(const Piece &piece, const Vector3 &from, const Vector3 &to) {
	if (piece.kind == BOUNDARY) {
		const double start = piece.plane.distance_to(from);
		return start >= 0.0 && piece.plane.distance_to(to) <= 0.0; // from in front to behind
	}
	const D3 p0(piece.from_world.xform(from));
	const D3 p1(piece.from_world.xform(to));
	const D3 d = p1 - p0;
	switch (piece.kind) {
		case BOX: {
			const double e[3] = { piece.half_extents.x, piece.half_extents.y, piece.half_extents.z };
			const double start[3] = { p0.x, p0.y, p0.z };
			const double along[3] = { d.x, d.y, d.z };
			if (std::abs(p0.x) < e[0] && std::abs(p0.y) < e[1] && std::abs(p0.z) < e[2]) {
				return false;
			}
			double t0 = 0.0;
			double t1 = 1.0;
			for (int axis = 0; axis < 3; ++axis) {
				if (std::abs(along[axis]) < 1e-12) {
					if (std::abs(start[axis]) > e[axis]) {
						return false;
					}
					continue;
				}
				double ta = (-e[axis] - start[axis]) / along[axis];
				double tb = (e[axis] - start[axis]) / along[axis];
				if (ta > tb) {
					std::swap(ta, tb);
				}
				t0 = std::max(t0, ta);
				t1 = std::min(t1, tb);
				if (t0 > t1) {
					return false;
				}
			}
			return true;
		}
		case SPHERE: {
			const double r2 = piece.radius * piece.radius;
			if (p0.dot(p0) < r2) {
				return false;
			}
			return point_segment_distance_squared(D3(0.0, 0.0, 0.0), p0, p1) <= r2;
		}
		case CAPSULE: {
			const double r2 = piece.radius * piece.radius;
			const D3 bottom(0.0, -piece.half_height, 0.0);
			const D3 top(0.0, piece.half_height, 0.0);
			if (point_segment_distance_squared(p0, bottom, top) < r2) {
				return false;
			}
			return segment_distance_squared(p0, p1, bottom, top) <= r2;
		}
		default: { // CYLINDER, upright in its own space
			const double r2 = piece.radius * piece.radius;
			const double h = piece.half_height;
			if (std::abs(p0.y) < h && p0.x * p0.x + p0.z * p0.z < r2) {
				return false;
			}
			// The part of the ray between the two caps' heights...
			double ta = 0.0;
			double tb = 1.0;
			if (std::abs(d.y) < 1e-12) {
				if (std::abs(p0.y) > h) {
					return false;
				}
			} else {
				ta = (-h - p0.y) / d.y;
				tb = (h - p0.y) / d.y;
				if (ta > tb) {
					std::swap(ta, tb);
				}
				ta = std::max(ta, 0.0);
				tb = std::min(tb, 1.0);
				if (ta > tb) {
					return false;
				}
			}
			// ...comes within the radius of the axis, seen from above.
			const double qx = p0.x;
			const double qz = p0.z;
			const double length = d.x * d.x + d.z * d.z;
			double t = ta;
			if (length > 1e-12) {
				t = std::clamp(-(qx * d.x + qz * d.z) / length, ta, tb);
			}
			const double cx = qx + d.x * t;
			const double cz = qz + d.z * t;
			return cx * cx + cz * cz <= r2;
		}
	}
}

void SightGeometry::_bind_methods() {
	ClassDB::bind_method(D_METHOD("find_ground", "point", "top", "bottom", "mask"), &SightGeometry::find_ground);
	ClassDB::bind_method(D_METHOD("add_body", "body"), &SightGeometry::add_body);
	ClassDB::bind_method(D_METHOD("remove_body", "body"), &SightGeometry::remove_body);
	ClassDB::bind_method(D_METHOD("mark_dirty", "body"), &SightGeometry::mark_dirty);
	ClassDB::bind_method(D_METHOD("sync", "tick"), &SightGeometry::sync);
	ClassDB::bind_method(D_METHOD("is_blocked", "from", "to", "mask"), &SightGeometry::is_blocked);
	ClassDB::bind_method(D_METHOD("set_cell_size", "size"), &SightGeometry::set_cell_size);
	ClassDB::bind_method(D_METHOD("get_cell_size"), &SightGeometry::get_cell_size);
	ClassDB::bind_method(D_METHOD("get_stats"), &SightGeometry::get_stats);
	ClassDB::bind_method(D_METHOD("clear"), &SightGeometry::clear);
}
