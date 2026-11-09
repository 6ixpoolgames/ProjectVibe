// Written by Claude (claude-opus-5-5), 2026-11-03: GDExtension entry point; registers NavHooks and the NavServer singleton.
#include "ai_memory_store.h" // Claude 2026-11-09: AI memory and sight in C++, pawn spec 10.11
#include "ai_pawn_grid.h" // Claude 2026-11-09
#include "nav_hooks.h"
#include "nav_server.h"
#include "net_codec.h" // Claude 2026-11-05: packet encoding in C++, a measured test the game doesn't use yet
#include "tick_state_recorder.h" // Claude 2026-11-09: rollback recording in C++, pawn spec 12.1
#include "pawn_table.h" // Claude 2026-11-09: the shared table of plain pawn data, scaling spec step 1
#include "job_scheduler.h" // Claude 2026-11-09: worker threads for plain-data jobs, scaling spec step 2
#include "ai_sensing_job.h" // Claude 2026-11-09: the first job kind, sensing, step 2

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
	GDREGISTER_CLASS(NetCodec); // Claude 2026-11-05
	GDREGISTER_CLASS(AIMemoryStore); // Claude 2026-11-09
	GDREGISTER_CLASS(PawnTable); // Claude 2026-11-09: before AIPawnGrid, which uses it
	GDREGISTER_CLASS(AIPawnGrid); // Claude 2026-11-09
	GDREGISTER_CLASS(JobScheduler); // Claude 2026-11-09, step 2
	GDREGISTER_CLASS(AISensingJob); // Claude 2026-11-09, step 2: after the grid and the scheduler it uses
	GDREGISTER_CLASS(TickStateRecorder); // Claude 2026-11-09
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
