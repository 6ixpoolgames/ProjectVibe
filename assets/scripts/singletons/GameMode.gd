# Written by Claude (claude-opus-5-5), 2026-11-07. History: game_mode/CHANGELOG.md.
## The shell of the game's rules: holds the game's modules. Autoload "GameMode".
##
## "Game mode" is Unreal's name for this job. Here it holds optional modules and does almost nothing itself, so an empty one costs
## nothing, and each piece of a game's rules can be swapped or left out on its own.
## [br]
## The base's modules:
## [br]- [PawnInitializer]: gives each pawn its default parts, from one list per game.
## [br]- [PossessionCoordinator]: creates the PlayerController, and tracks who controls which pawn.
## [br]- [AIActivationManager]: switches AI pawns off when no source keeps the ground under them loaded, and sets how often the rest run.
## [br]- [SpawnManager]: puts pawns in at SpawnPoints, and brings players back after they die.
## [br]- [ReplayRecorder]: records the game to a replay file once the game calls start_recording (replay spec).
## [br]- [TeamRegistry]: how many pawns are on each team.
## [br]- [CrowdMover]: moves AI pawns walking on the ground as one crowd.
## [br]
## How to use it:
## [codeblock]
## GameMode.pawn_initializer         # a module, or null if this game doesn't have it, so check first
## GameMode.possession_coordinator   # the same, and so on for each module above
## GameMode.get_module(SomeScript)   # any module by its script
## GameMode.add_module(node)         # a game's own modules, which extend GameModeModule
## [/codeblock]
## Which modules start with the game comes from the project setting "project_base/game_mode/modules", a list of script paths
## (with a ".release" override for release builds). With no setting, it starts the ones in [constant DEFAULT_MODULES]. An empty list
## starts none, and the game still runs.
## [br]
## What happens in odd cases (all checked in game_mode/tests/game_mode_selftest.gd):
## [br]- A path in the setting that doesn't load, or isn't a GameModeModule: it warns and carries on without that module.
## [br]- Adding a second module of the same type: it warns and keeps the first.
# REFACTOR: the autoload has a named line for every base module (from game_mode/, replay/ and movement/), so adding a module to the
# base means editing the autoload. Modules naming themselves, with get_module for the rest, would keep it universal (extensible).
extends Node
class_name GameModeSingleton

## Sent when a module has started.
signal module_added(module: GameModeModule)
## Sent when a module has stopped, just before it's freed.
signal module_removed(module: GameModeModule)

## The project setting that lists the modules to start, as script paths.
const MODULES_SETTING := "project_base/game_mode/modules"
# REFACTOR: DEFAULT_MODULES is a second copy of the project setting's list, and it has drifted (the setting also starts
# DiagnosticsManager). One list, in one place, is easier for a designer to keep right.
## The modules started when the project setting isn't there, in this order.
const DEFAULT_MODULES: Array[String] = [
	"res://assets/scripts/game_mode/PawnInitializer.gd", # first, so it's ready before any pawn arrives
	"res://assets/scripts/game_mode/PossessionCoordinator.gd",
	"res://assets/scripts/game_mode/AIActivationManager.gd",
	"res://assets/scripts/game_mode/SpawnManager.gd", # does nothing with no spawn points placed
	"res://assets/scripts/replay/ReplayRecorder.gd", # records nothing until the game starts a recording
	"res://assets/scripts/game_mode/TeamRegistry.gd",
	"res://assets/scripts/movement/CrowdMover.gd", # does nothing until an AI pawn walks
	"res://assets/scripts/ai/AIDecisionModule.gd", # the AI decides in C++ (the main path)
]

## The module that switches AI pawns off, or null without one. Each module fills in its own line when it starts.
var ai_activation_manager: AIActivationManager = null
## Who controls which pawn, or null without one.
var possession_coordinator: PossessionCoordinator = null
## Gives pawns their default parts, or null without one.
var pawn_initializer: PawnInitializer = null
## Spawns pawns at spawn points and brings players back, or null without one.
var spawn_manager: SpawnManager = null
## Records the game to replay files, or null without one (docs/replay/REPLAY_SPEC.md).
var replay_recorder: ReplayRecorder = null
## How many pawns are on each team, or null without one.
var team_registry: TeamRegistry = null
## Moves AI pawns walking on the ground as one crowd (pawn spec 8.22), or null without one.
var crowd_mover: CrowdMover = null

var _modules: Array[GameModeModule] = []


func _ready() -> void:
	# GDScript note: this script does no work per frame. Its modules each decide whether they need to.
	set_process(false)
	set_physics_process(false)
	var paths: Array = ProjectSettings.get_setting(MODULES_SETTING, DEFAULT_MODULES)
	for path: String in paths:
		var script: Variant = load(path) if ResourceLoader.exists(path) else null
		var module: Variant = script.new() if script is GDScript else null
		if module is GameModeModule:
			add_module(module)
		else:
			push_warning("GameMode: '%s' isn't a GameModeModule, so this game runs without it." % path)
			if module is Object and not (module is RefCounted):
				module.free()


## Starts a module. It stays until [method remove_module] or until the game ends.
func add_module(module: GameModeModule) -> void:
	if module == null:
		return
	if get_module(module.get_script()) != null:
		push_warning("GameMode: there's already a %s, so this one wasn't added." % module.get_script().get_global_name())
		module.free()
		return
	_modules.append(module)
	add_child(module)
	module._on_module_added(self)
	module_added.emit(module)


## Stops a module and frees it. Anything using it should check again, because it's gone.
func remove_module(module: GameModeModule) -> void:
	if module == null or not _modules.has(module):
		return
	_modules.erase(module)
	module._on_module_removed(self)
	remove_child(module)
	module_removed.emit(module)
	module.free()


## The module made from this script, or null if there isn't one.
func get_module(script: Script) -> GameModeModule:
	for module in _modules:
		if module.get_script() == script:
			return module
	return null


## Every module right now. Read it, don't change it.
func get_modules() -> Array[GameModeModule]:
	return _modules
