## Written by Claude (claude-opus-5-5), 2026-11-07: the shell of the game's rules. Autoload "GameMode".
## "Game mode" is Unreal's name for this job. Here it holds optional modules and does almost nothing itself, so an empty one
## costs nothing, and each piece of a game's rules can be swapped or left out on its own.
##
## Modules so far:
##   PawnInitializer         gives each pawn its default parts, from one list per game (Claude 2026-11-07)
##   PossessionCoordinator   creates the PlayerController, and tracks who controls which pawn
##   AIActivationManager     switches AI pawns off when no source keeps the ground under them loaded
##
## How to use it:
##   GameMode.pawn_initializer         # a module, or null if this game doesn't have it, so check first
##   GameMode.possession_coordinator   # the same
##   GameMode.ai_activation_manager    # the same
##   GameMode.get_module(SomeScript)   # any module by its script
##   GameMode.add_module(node)         # a game's own modules, which extend GameModeModule
##
## Which modules start with the game comes from the project setting "project_base/game_mode/modules", a list of script paths.
## With no setting, it starts the ones in DEFAULT_MODULES. An empty list starts none, and the game still runs.
##
## What happens in odd cases (all checked in game_mode/tests/game_mode_selftest.gd):
##   - A path in the setting that doesn't load, or isn't a GameModeModule: it warns and carries on without that module.
##   - Adding a second module of the same type: it warns and keeps the first.
extends Node
class_name GameModeSingleton

signal module_added(module: GameModeModule)
signal module_removed(module: GameModeModule)

const MODULES_SETTING := "project_base/game_mode/modules"
const DEFAULT_MODULES: Array[String] = [
	"res://assets/scripts/game_mode/PawnInitializer.gd", # Claude 2026-11-07: first, so it's ready before any pawn arrives
	"res://assets/scripts/game_mode/PossessionCoordinator.gd",
	"res://assets/scripts/game_mode/AIActivationManager.gd",
]

## The module that switches AI pawns off, or null without one. Each module fills in its own line when it starts.
# Claude 2026-11-07: renamed from ai_activity and possession, so that each name says what the module does.
var ai_activation_manager: AIActivationManager = null
## Who controls which pawn, or null without one.
var possession_coordinator: PossessionCoordinator = null
## Claude 2026-11-07: gives pawns their default parts, or null without one.
var pawn_initializer: PawnInitializer = null

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


## Starts a module. It stays until remove_module or until the game ends.
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
