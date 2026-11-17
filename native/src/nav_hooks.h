// Written by Claude (claude-opus-5-5), 2026-11-03. History: native/CHANGELOG.md.
// NavHooks: a Resource that says how a piece of the level feeds nav (nav spec 5.1). A feeder with a NavHooks feeds the nav
// system; a level piece without one is invisible to it.
//
// GDScript: world/TerrainNavFeeder and world/BodyNavFeeder pass one to NavServer.add_input_layer. layer_op says whether the
// layer adds solid ground, carves it away or only changes surface types; order sorts layers; surface_map turns the generator's
// material ids into nav surface names.
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
	// Not used yet: estimates are for the coarse planner (phase 5). Link hints were planned with links (phase 3), but links came
	// another way: the tile build finds jumps and drops itself, and NavServer.add_link places the rest.
	// REFACTOR: two settings in the inspector that do nothing (designer friendly): hide them until something reads them.
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
