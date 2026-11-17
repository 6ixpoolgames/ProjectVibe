# Written by Claude (claude-opus-5-5), 2026-11-16. History: game_mode/CHANGELOG.md.
## How many pawns are on each team, kept current as pawns enter and leave the tree and change team.
##
## A module of GameMode, reached as GameMode.team_registry. AI sensing asks it whether there's anyone on another team at all, and skips
## looking when there isn't (pawn spec 10.4). Team counts are a GameMode module's job, not the pawn's (the owner's call).
## [br]
## How it keeps count: every pawn joins Pawn.GROUP when it enters the tree, so the pawns already there are counted when this module
## starts; after that, the tree's node_added and node_removed signals, and each pawn's team_changed signal.
## [br]
## Without this module (a game that leaves it out), nothing breaks: sensing just looks every time, as if someone might be there.
class_name TeamRegistry
extends GameModeModule

var _counts := {} # team -> how many pawns in the tree are on it
var _watched := {} # pawn instance id -> true, for pawns counted and connected


func _init() -> void:
	# GDScript note: this module does no work per frame; it works from signals.
	set_process(false)
	set_physics_process(false)


func _on_module_added(game_mode: GameModeSingleton) -> void:
	game_mode.team_registry = self
	_counts.clear()
	_watched.clear()
	for node in get_tree().get_nodes_in_group(Pawn.GROUP): # the list of all pawns
		if node is Pawn:
			_add(node)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	game_mode.team_registry = null
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	if get_tree().node_removed.is_connected(_on_node_removed):
		get_tree().node_removed.disconnect(_on_node_removed)


## How many pawns in the tree are on this team.
func count_on_team(team: int) -> int:
	return _counts.get(team, 0)


## How many pawns in the tree are on any team but this one. AI sensing skips looking when it's 0.
func count_not_on_team(team: int) -> int:
	var total := 0
	for each_team: int in _counts:
		if each_team != team:
			total += _counts[each_team]
	return total


## Every team with pawns on it, and how many: a copy, so changing it changes nothing here.
func get_counts() -> Dictionary:
	return _counts.duplicate()


func _on_node_added(node: Node) -> void:
	if node is Pawn:
		_add(node)


func _on_node_removed(node: Node) -> void:
	if not (node is Pawn) or not _watched.has(node.get_instance_id()):
		return
	_watched.erase(node.get_instance_id())
	var pawn := node as Pawn
	_change(pawn.team, -1)
	if pawn.team_changed.is_connected(_on_team_changed):
		pawn.team_changed.disconnect(_on_team_changed)


func _add(pawn: Pawn) -> void:
	if _watched.has(pawn.get_instance_id()):
		return
	_watched[pawn.get_instance_id()] = true
	_change(pawn.team, 1)
	pawn.team_changed.connect(_on_team_changed)


func _on_team_changed(_pawn: Pawn, old_team: int, new_team: int) -> void:
	_change(old_team, -1)
	_change(new_team, 1)


func _change(team: int, by: int) -> void:
	var count: int = _counts.get(team, 0) + by
	if count <= 0:
		_counts.erase(team)
	else:
		_counts[team] = count
