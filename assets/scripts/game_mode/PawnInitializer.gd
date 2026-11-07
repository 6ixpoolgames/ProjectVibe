## Written by Claude (claude-opus-5-5), 2026-11-07: gives every pawn the parts it needs to work, from one list per game. A module of
## GameMode, reached as GameMode.pawn_initializer. Pawn spec section 11. It replaces the old idea of a nexus node on every pawn.
##
## How it works: a Pawn calls GameMode.pawn_initializer.initialize(self) from its own _enter_tree. For each part in the game's
## defaults file, in order, it adds that part unless the pawn already has a child of the same name. So:
##   - a designer overrides a default by putting their own part with that name in the pawn's scene, and
##   - parts get the same names in the same order on every machine.
## A pawn adds to itself here, rather than a child adding to it, because Godot doesn't let a child add to its parent while the
## scene is starting up.
##
## The defaults file is resources/pawn_defaults.tres (a PawnDefaultsRes), or the one named by the project setting
## "project_base/game_mode/pawn_defaults". For t0 it holds today's parts: ControllerManager (with its AIController) and GroundMovement.
##
## What it never adds: TickStateComponent and NetworkEntity. NetworkSession reads those as soon as it creates a pawn, before the pawn
## joins the tree, so they have to be in the pawn's scene.
##
## Ways out:
##   - one pawn, every default: turn off Pawn.fill_in_default_parts
##   - one pawn, some defaults: list their names in Pawn.skip_default_parts
##   - the whole game: leave this module out of GameMode's list, and pawns get only what their scenes have
##
## What happens in odd cases (all checked in tests/pawn_initializer_selftest.gd):
##   - No defaults file, or the wrong kind of file: a warning, and pawns get nothing added.
##   - An empty slot in the list: skipped.
##   - A pawn enters the tree again, such as after being moved: nothing is added twice, because its parts are already there.
class_name PawnInitializer
extends GameModeModule

const DEFAULTS_SETTING := "project_base/game_mode/pawn_defaults"
const DEFAULT_DEFAULTS_PATH := "res://assets/scripts/resources/pawn_defaults.tres"

## The defaults in use. Read from the file when the module starts. A test or a game can set its own.
var defaults: PawnDefaultsRes = null


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _on_module_added(game_mode: GameModeSingleton) -> void:
	game_mode.pawn_initializer = self
	if defaults == null:
		defaults = _load_defaults()


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	game_mode.pawn_initializer = null


## Adds each default part this pawn doesn't have yet. The pawn calls this from its _enter_tree.
func initialize(pawn: Pawn) -> void:
	if pawn == null or defaults == null or not pawn.fill_in_default_parts:
		return
	for scene in defaults.parts:
		if scene == null:
			continue
		var part_name := part_name_of(scene)
		if part_name == &"" or pawn.skip_default_parts.has(part_name) or pawn.has_node(NodePath(String(part_name))):
			continue
		pawn.add_child(scene.instantiate())


## The name a part gets on the pawn: its scene's root node name. Read without making the scene.
static func part_name_of(scene: PackedScene) -> StringName:
	var state := scene.get_state()
	return state.get_node_name(0) if state.get_node_count() > 0 else &""


func _load_defaults() -> PawnDefaultsRes:
	var path: String = ProjectSettings.get_setting(DEFAULTS_SETTING, DEFAULT_DEFAULTS_PATH)
	var res: Variant = load(path) if path != "" and ResourceLoader.exists(path) else null
	if res is PawnDefaultsRes:
		return res
	push_warning("PawnInitializer: no PawnDefaultsRes at '%s', so pawns only get the parts their own scenes have." % path)
	return null
