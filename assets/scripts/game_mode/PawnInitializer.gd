# Written by Claude (claude-opus-5-5), 2026-11-07. History: game_mode/CHANGELOG.md.
## Gives every pawn the parts it needs to work, from one list per game.
##
## A module of GameMode (GameMode.pawn_initializer). A Pawn calls [method initialize] from its _enter_tree; for each part in the
## defaults file, in order, it adds the part unless the pawn already has a child of that name. So a designer overrides a default by
## putting their own part with that name in the scene, and every machine gets the same names in the same order. A part's own
## components (the children its scene instances from scenes of their own, such as the AIManager's) are filled in the same way: a pawn
## with its own AIManager holding only an AIBehaviourManager gets the default sensing, memory and the rest. The defaults are
## resources/pawn_defaults.tres (a [PawnDefaultsRes]) or the file named by the project setting
## [code]project_base/game_mode/pawn_defaults[/code]. It never adds TickStateComponent or NetworkEntity: NetworkSession reads them
## before the pawn joins the tree, so they stay in the scene.
## [br]
## To opt out: Pawn.fill_in_default_parts off (one pawn, every default), Pawn.skip_default_parts (some parts or components, by
## name), or leave this module out of GameMode (the whole game). Design: pawn spec 11.
class_name PawnInitializer
extends GameModeModule

## The project setting naming the defaults file, if a game uses another.
const DEFAULTS_SETTING := "project_base/game_mode/pawn_defaults"
## The defaults file used without that setting.
const DEFAULT_DEFAULTS_PATH := "res://assets/scripts/resources/pawn_defaults.tres"

## The defaults in use. Read from the file when the module starts. A test or a game can set its own.
var defaults: PawnDefaultsRes = null
var _brain_warned := false # whether the brain-matches-nothing warning was given
var _components_of := {} # a part's scene -> its components, as [name, scene] pairs (components_of)


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
	if pawn == null:
		return
	# The game's crowd mover moves it, if the game has one and nothing set another.
	var game_mode := get_parent() as GameModeSingleton
	if pawn.mover == null and game_mode and game_mode.crowd_mover:
		pawn.mover = game_mode.crowd_mover
	if defaults == null or not pawn.fill_in_default_parts:
		return
	# The game's AI brain, if it sets one, goes in place of the part or component of the same name (PawnDefaultsRes.ai_brain). Its
	# name is read once here, not for every part.
	var brain_part: StringName = part_name_of(defaults.ai_brain) if defaults.ai_brain else &""
	for scene in defaults.parts:
		if scene == null:
			continue
		var part_name := part_name_of(scene)
		if part_name == &"" or pawn.skip_default_parts.has(part_name):
			continue
		var part := pawn.get_node_or_null(NodePath(String(part_name)))
		if part:
			_add_missing_components(pawn, part, scene, brain_part) # the pawn's own part keeps what it has
			continue
		part = (defaults.ai_brain if part_name == brain_part else scene).instantiate()
		_trim_components(pawn, part, scene, brain_part)
		pawn.add_child(part)
	_warn_if_brain_matches_nothing(brain_part)


# A part the pawn's scene already has gets each default component it lacks, by name, after its own.
func _add_missing_components(pawn: Pawn, part: Node, scene: PackedScene, brain_part: StringName) -> void:
	for pair: Array in components_of(scene):
		var component_name: StringName = pair[0]
		if pawn.skip_default_parts.has(component_name) or part.has_node(NodePath(String(component_name))):
			continue
		var component_scene: PackedScene = defaults.ai_brain if component_name == brain_part else pair[1]
		part.add_child(component_scene.instantiate())


# A part just made from its default scene: the skipped components go, and the brain goes in place of its namesake.
func _trim_components(pawn: Pawn, part: Node, scene: PackedScene, brain_part: StringName) -> void:
	for pair: Array in components_of(scene):
		var component_name: StringName = pair[0]
		var component := part.get_node_or_null(NodePath(String(component_name)))
		if component == null:
			continue
		if pawn.skip_default_parts.has(component_name):
			part.remove_child(component)
			component.free()
		elif component_name == brain_part:
			var index := component.get_index()
			part.remove_child(component)
			component.free()
			var brain := defaults.ai_brain.instantiate()
			part.add_child(brain)
			part.move_child(brain, index)


## A part's components: the children its scene instances from scenes of their own, as [name, scene] pairs in order. Read without
## making the scene, once per scene.
func components_of(scene: PackedScene) -> Array:
	if _components_of.has(scene):
		return _components_of[scene]
	var found := []
	var state := scene.get_state()
	for i in range(1, state.get_node_count()):
		var component_scene := state.get_node_instance(i)
		if component_scene and state.get_node_path(i, true) == ^".":
			found.append([state.get_node_name(i), component_scene])
	_components_of[scene] = found
	return found


# A brain whose root isn't named like any part or component in the list is never used, which would be silent. Said once.
func _warn_if_brain_matches_nothing(brain_part: StringName) -> void:
	if brain_part == &"" or _brain_warned:
		return
	for scene in defaults.parts:
		if scene == null:
			continue
		if part_name_of(scene) == brain_part:
			return
		for pair: Array in components_of(scene):
			if pair[0] == brain_part:
				return
	_brain_warned = true
	push_warning("[PawnInitializer] the AI brain's root is named '%s', but no part or component in the defaults list has that name, so it's never used. Name its root like the AIManager's AIBehaviourManager." % brain_part)


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
