# Written by Claude (claude-opus-5-5), 2026-11-07. History: stats/CHANGELOG.md.
## Holds a pawn's stats, one [Stat] node each, and finds them by name.
##
## A part on the pawn, added by PawnInitializer (pawn spec 9). A Stat's name is its node's name; stats can be added and removed while
## running. A missing stat is never an error: [method get_value] gives the fallback and [method get_stat] gives null. A stat that
## changes during play is filled and listed for rollback when the manager is ready, so one added later starts at 0 and doesn't roll back.
## [codeblock]
## pawn.stat_manager.get_value(&"MoveSpeed", 5.0)   # the value, or the fallback if there's no such stat
## pawn.stat_manager.get_current(&"Health", 0.0)    # how much a stat that changes during play has now
## pawn.stat_manager.change_current(&"Health", -20) # the server: adds, kept between 0 and its value; returns the new amount
## [/codeblock]
## Everything that means "the pawn's health" reads [constant HEALTH].
class_name StatManager
extends Node

## The name of the Health stat. A pawn without a stat of this name can't be hurt or die from damage.
const HEALTH := &"Health"
## The name of the Detectability stat: how easy the pawn is for AI to see (1 normal, 0 invisible). [method detectability_of] reads
## it, and it's copied into the pawn table for the sensing job ([member Stat.table_column]).
const DETECTABILITY := &"Detectability"


## How easy this pawn is for AI to see: its Detectability stat's value, 1 without one (pawn spec 10.4). Effects change it through the
## stat; game rules for stealth belong in a GameMode module.
static func detectability_of(of_pawn: Node) -> float:
	var manager: StatManager = of_pawn.get(&"stat_manager") if of_pawn else null
	var stat: Stat = manager.get_stat(DETECTABILITY) if manager else null
	return stat.value if stat else 1.0


## Sets this pawn's Detectability stat's base value (what effects build on). Does nothing for a pawn without the stat.
# REFACTOR: only tests call it; a test helper in tests/ would keep it out of the shipping class (stats/CHANGELOG.md).
static func set_detectability(of_pawn: Node, value: float) -> void:
	var manager: StatManager = of_pawn.get(&"stat_manager") if of_pawn else null
	var stat: Stat = manager.get_stat(DETECTABILITY) if manager else null
	if stat:
		stat.base_value = value

var _stats := {} # StringName -> Stat
var pawn: Pawn = null # the pawn this is a part of, or null outside a pawn
## Goes up by one whenever a stat's value changes, or a stat is added or removed (not when a current value such as Health changes).
## An ability that keeps stat values reads them again only when this has changed (pawn spec 15.2).
var version := 1


func _init() -> void:
	set_process(false)
	set_physics_process(false)
	# These fire for children added at any time, including the scene's own as they enter the tree.
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	# It tells its pawn it's here, before any part's _ready; the first StatManager a pawn has is the one it uses.
	if pawn and not is_instance_valid(pawn.stat_manager):
		pawn.stat_manager = self


# Stats that change during play start full, and their current values roll back. Runs before the first tick.
func _ready() -> void:
	var entries: Array[String] = []
	var recorded: Array[Stat] = []
	for stat_name: StringName in _stats:
		var stat: Stat = _stats[stat_name]
		if stat.changes_during_play:
			stat.current = stat.value
			if pawn:
				entries.append("%s:current pushed" % String(pawn.get_path_to(stat)))
				recorded.append(stat)
	if pawn and not entries.is_empty():
		for child in pawn.get_children():
			if child is TickStateComponent:
				child.add_state_properties(entries)
				# Each stat pushes its current value when it changes, instead of the store reading it every tick.
				for stat in recorded:
					stat._tick_state = child
					stat._state_key = "%s:current" % String(pawn.get_path_to(stat))
				break


## How much Health the pawn has now, or 0 without a Health stat.
func get_health() -> float:
	return get_current(HEALTH, 0.0)


## How much a stat that changes during play has now, or the fallback if there's no such stat.
func get_current(stat_name: StringName, fallback := 0.0) -> float:
	var stat: Stat = _stats.get(stat_name)
	return stat.current if stat and stat.changes_during_play else fallback


## Adds to a stat that changes during play (negative takes away), kept between 0 and its value. Returns the new amount, or 0 if
## there's no such stat. Only the server should change it: clients get it in snapshots.
func change_current(stat_name: StringName, amount: float) -> float:
	var stat: Stat = _stats.get(stat_name)
	if stat == null or not stat.changes_during_play:
		return 0.0
	stat.current = clampf(stat.current + amount, 0.0, stat.value)
	return stat.current


## The stat's value right now, or fallback if this pawn has no such stat.
func get_value(stat_name: StringName, fallback := 0.0) -> float:
	var stat: Stat = _stats.get(stat_name)
	return stat.value if stat else fallback


## The Stat node, or null if there's none with that name.
func get_stat(stat_name: StringName) -> Stat:
	return _stats.get(stat_name)


## True if this pawn has a stat with that name.
func has_stat(stat_name: StringName) -> bool:
	return _stats.has(stat_name)


## Every stat's name.
func get_stat_names() -> Array[StringName]:
	var names: Array[StringName] = []
	for stat_name: StringName in _stats:
		names.append(stat_name)
	return names


func _on_child_entered(node: Node) -> void:
	if node is Stat:
		_stats[StringName(node.name)] = node
		version += 1


func _on_child_exiting(node: Node) -> void:
	if node is Stat and _stats.get(StringName(node.name)) == node:
		_stats.erase(StringName(node.name))
		version += 1
