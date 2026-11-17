// Written by Claude (claude-opus-5-5), 2026-11-03. History: native/CHANGELOG.md.
// The navcore library's GDExtension entry point (bin/navcore.gdextension names navcore_library_init). It registers every class
// GDScript can make, and the NavServer engine singleton. native/README.md lists the classes and which scripts use them.
#include "ai_memory_store.h" // AI memory and sight in C++, pawn spec 10.11
#include "ai_pawn_grid.h" // who's near whom, for sensing and swing hits
#include "nav_hooks.h"
#include "nav_server.h"
#include "net_codec.h" // snapshot encoding in C++, NetworkSession's fast path
#include "tick_state_recorder.h" // rollback recording in C++, pawn spec 12.1
#include "pawn_table.h" // the shared table of plain pawn data, scaling spec step 1
#include "job_scheduler.h" // worker threads for plain-data jobs, scaling spec step 2
#include "ai_sensing_job.h" // sensing's search on the workers, step 2
#include "sight_geometry.h" // line of sight in C++, step 4
#include "replay_motion_packer.h" // the replay's motion packing in C++
#include "crowd_batch.h" // the crowd mover's batch in C++

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
	GDREGISTER_CLASS(NetCodec);
	GDREGISTER_CLASS(AIMemoryStore);
	GDREGISTER_CLASS(PawnTable); // before AIPawnGrid, which uses it
	GDREGISTER_CLASS(AIPawnGrid);
	GDREGISTER_CLASS(SightGeometry); // before the job and the store, which use it
	GDREGISTER_CLASS(JobScheduler);
	GDREGISTER_CLASS(AISensingJob); // after the grid and the scheduler it uses
	GDREGISTER_CLASS(TickStateRecorder);
	GDREGISTER_CLASS(ReplayMotionPacker);
	GDREGISTER_CLASS(CrowdBatch); // after the scheduler and the geometry it uses
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
