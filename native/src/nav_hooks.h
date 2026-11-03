// Written by Claude (claude-opus-5-5), 2026-11-03: NavHooks resource, the opt-in a terrain generator carries (spec 5.1).
// A generator with a NavHooks feeds the nav system; one without is invisible to it.
#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class NavHooks : public Resource {
	GDCLASS(NavHooks, Resource)

public:
	enum LayerOp {
		LAYER_OP_ADD = 0, // union solid (ground, buildings)
		LAYER_OP_CARVE = 1, // subtract solid (caves, craters)
		LAYER_OP_SURFACE = 2, // only change surface types (roads, mud)
	};

	void set_layer_op(int op) { m_layer_op = op; }
	int get_layer_op() const { return m_layer_op; }
	void set_order(int order) { m_order = order; }
	int get_order() const { return m_order; }
	// generator material id (int) -> nav surface name (String), e.g. { 3: "road" }
	void set_surface_map(const Dictionary &map) { m_surface_map = map; }
	Dictionary get_surface_map() const { return m_surface_map; }
	// Not used yet: estimates arrive with the coarse planner (phase 5), link hints with links (phase 3).
	void set_send_estimates(bool v) { m_send_estimates = v; }
	bool get_send_estimates() const { return m_send_estimates; }
	void set_send_link_hints(bool v) { m_send_link_hints = v; }
	bool get_send_link_hints() const { return m_send_link_hints; }

protected:
	static void _bind_methods();

private:
	int m_layer_op = LAYER_OP_ADD;
	int m_order = 0;
	Dictionary m_surface_map;
	bool m_send_estimates = true;
	bool m_send_link_hints = true;
};

} // namespace godot

VARIANT_ENUM_CAST(NavHooks::LayerOp);
