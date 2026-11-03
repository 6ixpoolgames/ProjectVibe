// Written by Claude (claude-opus-5-5), 2026-11-03: NavHooks resource, the opt-in a terrain generator carries (spec 5.1).
#include "nav_hooks.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void NavHooks::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_layer_op", "op"), &NavHooks::set_layer_op);
	ClassDB::bind_method(D_METHOD("get_layer_op"), &NavHooks::get_layer_op);
	ClassDB::bind_method(D_METHOD("set_order", "order"), &NavHooks::set_order);
	ClassDB::bind_method(D_METHOD("get_order"), &NavHooks::get_order);
	ClassDB::bind_method(D_METHOD("set_surface_map", "map"), &NavHooks::set_surface_map);
	ClassDB::bind_method(D_METHOD("get_surface_map"), &NavHooks::get_surface_map);
	ClassDB::bind_method(D_METHOD("set_send_estimates", "enabled"), &NavHooks::set_send_estimates);
	ClassDB::bind_method(D_METHOD("get_send_estimates"), &NavHooks::get_send_estimates);
	ClassDB::bind_method(D_METHOD("set_send_link_hints", "enabled"), &NavHooks::set_send_link_hints);
	ClassDB::bind_method(D_METHOD("get_send_link_hints"), &NavHooks::get_send_link_hints);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "layer_op", PROPERTY_HINT_ENUM, "Add,Carve,Surface"), "set_layer_op", "get_layer_op");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "order"), "set_order", "get_order");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "surface_map"), "set_surface_map", "get_surface_map");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "send_estimates"), "set_send_estimates", "get_send_estimates");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "send_link_hints"), "set_send_link_hints", "get_send_link_hints");

	BIND_ENUM_CONSTANT(LAYER_OP_ADD);
	BIND_ENUM_CONSTANT(LAYER_OP_CARVE);
	BIND_ENUM_CONSTANT(LAYER_OP_SURFACE);
}

} // namespace godot
