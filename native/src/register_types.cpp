// Written by Claude (claude-opus-5-5), 2026-11-03: GDExtension entry point; registers NavHooks and the NavServer singleton.
#include "nav_hooks.h"
#include "nav_server.h"

#include <gdextension_interface.h>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static NavServer *g_nav_server = nullptr;

static void initialize_navcore(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(NavHooks);
	GDREGISTER_CLASS(NavServer);
	g_nav_server = memnew(NavServer);
	Engine::get_singleton()->register_singleton("NavServer", g_nav_server);
}

static void uninitialize_navcore(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	Engine::get_singleton()->unregister_singleton("NavServer");
	memdelete(g_nav_server);
	g_nav_server = nullptr;
}

extern "C" {
GDExtensionBool GDE_EXPORT navcore_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
		const GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(initialize_navcore);
	init.register_terminator(uninitialize_navcore);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
}
