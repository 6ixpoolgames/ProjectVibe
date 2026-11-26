# Written by Claude (claude-opus-5-5), 2026-11-07. History: game_mode/CHANGELOG.md.
## The shell of the game's rules: holds the game's modules. Autoload "GameMode".
##
## It does almost nothing itself, so an empty one costs nothing and each piece of a game's rules can be swapped or left out. The modules
## to start come from the project setting [constant MODULES_SETTING] (script paths, with a ".release" override for release builds), else
## [constant DEFAULT_MODULES]; an empty list starts none. A path that doesn't load, or a second module of one type, warns and is skipped.
## [codeblock]
## GameMode.pawn_initializer        # a module, or null if this game doesn't have it, so check first
## GameMode.get_module(SomeScript)  # any module by its script
## GameMode.add_module(node)        # a game's own modules, which extend GameModeModule
## [/codeblock]
# REFACTOR: the autoload has a named line for every base module (from game_mode/, replay/ and movement/), so adding a module to the
# base means editing the autoload. Modules naming themselves, with get_module for the rest, would keep it universal (extensible).
# See game_mode/CHANGELOG.md.
extends Node
class_name GameModeSingleton

## Sent when a module has started.
signal module_added(module: GameModeModule)
## Sent when a module has stopped, just before it's freed.
signal module_removed(module: GameModeModule)

## The project setting that lists the modules to start, as script paths.
const MODULES_SETTING := "project_base/game_mode/modules"
# REFACTOR: DEFAULT_MODULES is a second copy of the project setting's list, and it has drifted (the setting also starts
# DiagnosticsManager). One list, in one place, is easier for a designer to keep right. See game_mode/CHANGELOG.md.
## The modules started when the project setting isn't there, in this order.
const DEFAULT_MODULES: Array[String] = [
	"res://assets/scripts/game_mode/PawnInitializer.gd", # first, so it's ready before any pawn arrives
	"res://assets/scripts/game_mode/PossessionCoordinator.gd",
	"res://assets/scripts/game_mode/AIActivationManager.gd",
	"res://assets/scripts/game_mode/SpawnManager.gd", # does nothing with no spawn points placed
	"res://assets/scripts/replay/ReplayRecorder.gd", # records nothing until the game starts a recording
	"res://assets/scripts/game_mode/TeamRegistry.gd",
	"res://assets/scripts/movement/CrowdMover.gd", # does nothing until an AI pawn walks
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

## The match's random seed (pawn spec 16.9): every [DeterministicRandom] roll mixes it in. Set it before the match starts, the same on
## every machine; setting it sets [member DeterministicRandom.match_seed]. 0 by default.
# REFACTOR: nothing sends it to clients yet, so a networked game that changes it must set the same value on every machine itself.
var match_seed := 0:
	set(value):
		match_seed = value
		DeterministicRandom.match_seed = value

var _modules: Array[GameModeModule] = []


func _ready() -> void:
	# No work per frame: its modules each decide whether they need to.
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
