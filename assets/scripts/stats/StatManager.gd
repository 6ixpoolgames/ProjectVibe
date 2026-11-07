## Written by Claude (claude-opus-5-5), 2026-11-07: holds a pawn's stats, one Stat node each. A part on the pawn, added by
## PawnInitializer. Pawn spec section 9.
##
## How to use it:
##   pawn.stat_manager.get_value(&"MoveSpeed", 5.0)   # the value, or the fallback if there's no such stat
##   pawn.stat_manager.get_stat(&"Health")            # the Stat node, or null
## A Stat's name is its node's name. Stats can be added and removed while running; the manager notices.
##
## What happens in odd cases (all checked in tests/stat_selftest.gd):
##   - A stat that isn't there: get_value gives the fallback, and get_stat gives null. Never an error.
##   - A child that isn't a Stat: ignored.
##   - Two stats with the same name can't happen, because Godot renames a second child with the same name.
class_name StatManager
extends Node

var _stats := {} # StringName -> Stat


func _init() -> void:
	set_process(false)
	set_physics_process(false)
	# GDScript note: these fire for children added at any time, including the scene's own children as they enter the tree.
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)


## The stat's value right now, or fallback if this pawn has no such stat.
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


func _on_child_exiting(node: Node) -> void:
	if node is Stat and _stats.get(StringName(node.name)) == node:
		_stats.erase(StringName(node.name))
