# Written by Claude (claude-opus-5-5), 2026-11-07. History: stats/CHANGELOG.md.
## Holds a pawn's stats, one [Stat] node each, and finds them by name.
##
## A part on the pawn, added by PawnInitializer. Pawn spec section 9.
## [br]
## How to use it:
## [codeblock]
## pawn.stat_manager.get_value(&"MoveSpeed", 5.0)   # the value, or the fallback if there's no such stat
## pawn.stat_manager.get_stat(&"Health")            # the Stat node, or null
## pawn.stat_manager.get_current(&"Health", 0.0)    # how much a stat that changes during play has now
## pawn.stat_manager.change_current(&"Health", -20) # the server: adds, kept between 0 and the stat's value; returns the new amount
## pawn.stat_manager.get_health()                   # how much Health the pawn has now, 0 without a Health stat
## [/codeblock]
## A Stat's name is its node's name. Stats can be added and removed while running; the manager notices. A stat that changes during
## play is filled and listed for rollback when the manager is ready, so one added later starts at 0 and doesn't roll back.
## [br]
## Health has one name, [constant HEALTH], which everything that means "the pawn's health" reads (Death, hits, the kill floor, the
## readouts). A fuller stats pass comes with the game mechanics.
## [br]
## What happens in odd cases (all checked in tests/stat_selftest.gd):
## [br]- A stat that isn't there: [method get_value] gives the fallback, and [method get_stat] gives null. Never an error.
## [br]- A child that isn't a Stat: ignored.
## [br]- Two stats with the same name can't happen, because Godot renames a second child with the same name.
class_name StatManager
extends Node

## The name of the Health stat. A pawn without a stat of this name can't be hurt or die from damage.
const HEALTH := &"Health"
## The name of the Detectability stat: how easy the pawn is for AI to see (1 normal, 0 invisible). [code]Pawn.detectability[/code]
## reads and writes it, and it's copied into the pawn table for the sensing job ([member Stat.table_column]).
const DETECTABILITY := &"Detectability"

var _stats := {} # StringName -> Stat
var pawn: Pawn = null # the pawn this is a part of, or null outside a pawn
## Goes up by one whenever a stat's value changes, or a stat is added or removed (not when a current value such as Health changes).
## An ability that keeps stat values reads them again only when this has changed (pawn spec 15.2).
var version := 1


func _init() -> void:
	set_process(false)
	set_physics_process(false)
	# GDScript note: these fire for children added at any time, including the scene's own children as they enter the tree.
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn


# Stats that change during play start full, and their current values roll back. Runs before the first tick.
func _ready() -> void:
	var entries: Array[String] = []
	for stat_name: StringName in _stats:
		var stat: Stat = _stats[stat_name]
		if stat.changes_during_play:
			stat.current = stat.value
			entries.append("%s:current" % String(pawn.get_path_to(stat)) if pawn else "")
	if pawn and not entries.is_empty():
		for child in pawn.get_children():
			if child is TickStateComponent:
				child.add_state_properties(entries)
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
