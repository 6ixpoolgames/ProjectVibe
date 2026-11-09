## Written by Claude (claude-opus-5-5), 2026-11-07: holds a pawn's stats, one Stat node each. A part on the pawn, added by
## PawnInitializer. Pawn spec section 9.
##
## How to use it:
##   pawn.stat_manager.get_value(&"MoveSpeed", 5.0)   # the value, or the fallback if there's no such stat
##   pawn.stat_manager.get_stat(&"Health")            # the Stat node, or null
##   pawn.stat_manager.get_current(&"Health", 0.0)    # Claude 2026-11-09: how much a stat that changes during play has now
##   pawn.stat_manager.change_current(&"Health", -20) # the server: adds, kept between 0 and the stat's value; returns the new amount
## A Stat's name is its node's name. Stats can be added and removed while running; the manager notices.
##
## What happens in odd cases (all checked in tests/stat_selftest.gd):
##   - A stat that isn't there: get_value gives the fallback, and get_stat gives null. Never an error.
##   - A child that isn't a Stat: ignored.
##   - Two stats with the same name can't happen, because Godot renames a second child with the same name.
class_name StatManager
extends Node

var _stats := {} # StringName -> Stat
var pawn: Pawn = null # Claude 2026-11-09
## Claude 2026-11-09: goes up by one whenever a stat's value changes, or a stat is added or removed (not when a current value such
## as Health changes). An ability that keeps stat values reads them again only when this has changed (pawn spec 15.2).
var version := 1


func _init() -> void:
	set_process(false)
	set_physics_process(false)
	# GDScript note: these fire for children added at any time, including the scene's own children as they enter the tree.
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)


## The stat's value right now, or fallback if this pawn has no such stat.
func _enter_tree() -> void:
	pawn = get_parent() as Pawn # Claude 2026-11-09


# Claude 2026-11-09: stats that change during play start full, and their current values roll back. Before the first tick.
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


## Claude 2026-11-09: how much a stat that changes during play has now, or the fallback if there's no such stat.
func get_current(stat_name: StringName, fallback := 0.0) -> float:
	var stat: Stat = _stats.get(stat_name)
	return stat.current if stat and stat.changes_during_play else fallback


## Claude 2026-11-09: adds to a stat that changes during play (negative takes away), kept between 0 and its value. Returns the new
## amount, or 0 if there's no such stat. Only the server should change it: clients get it in snapshots.
func change_current(stat_name: StringName, amount: float) -> float:
	var stat: Stat = _stats.get(stat_name)
	if stat == null or not stat.changes_during_play:
		return 0.0
	stat.current = clampf(stat.current + amount, 0.0, stat.value)
	return stat.current


func get_value(stat_name: StringName, fallback := 0.0) -> float:
	var stat: Stat = _stats.get(stat_name)
	return stat.value if stat else fallback


## The Stat node, or null if there's none with that name.
func get_stat(stat_name: StringName) -> Stat:
	return _stats.get(stat_name)


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
		version += 1 # Claude 2026-11-09


func _on_child_exiting(node: Node) -> void:
	if node is Stat and _stats.get(StringName(node.name)) == node:
		_stats.erase(StringName(node.name))
		version += 1 # Claude 2026-11-09
