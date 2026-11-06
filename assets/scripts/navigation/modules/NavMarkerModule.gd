## Written by Claude (claude-opus-5-5), 2026-11-06: the base for code that acts on nav markers (nav spec section 21.4).
## Markers are plain data. All the code for a kind of marker lives in a module, a node you add to a level that
## wants that behaviour and leave out of one that doesn't. A marker with no module simply does nothing.
##
## To make a module, extend this class, list your types in handled_types(), and fill in the calls you need:
##   class_name MyLadderModule extends NavMarkerModule
##   func handled_types() -> Array[Script]:
##       return [NavLink]
##   func _markers_added(ids: PackedInt64Array) -> void:
##       for id in ids:
##           var link: NavLink = NavWorld.get_marker(id)
##           ...
##
## Rules, all checked in tests/nav_markers_selftest.gd:
##   - Calls arrive during the tick, once per batch, with a list of ids rather than one call per marker.
##   - Load order doesn't matter. A module joining late gets every matching marker already there, on the next tick.
##   - A module handles subclasses of its types too, so a modder's subclass of NavLink just works.
##   - Several modules can handle one type.
##   - When a module leaves, it gets a final _markers_removed straight away, so it can undo exactly what it did.
##     Markers belong to NavWorld and stay registered, so other modules aren't affected.
##   - Requests made during a call wait for the next tick.
class_name NavMarkerModule
extends Node


## Announces which types this module works on. NavWorld asks once, when the module joins.
## Return [NavMarker] to get every kind of marker.
func handled_types() -> Array[Script]:
	return []


## Whether this module counts as handling its types in the debug report. Tools that only look at markers, like
## NavMarkerDebugModule, return false, or a debug drawing would hide that nothing actually acts on them.
func counts_for_report() -> bool:
	return true


## Markers arrived. NavWorld.get_marker(id) gives their full data.
func _markers_added(_ids: PackedInt64Array) -> void:
	pass


## Markers were switched on or off. NavWorld.is_marker_enabled(id) gives the new state.
func _markers_changed(_ids: PackedInt64Array) -> void:
	pass


## Markers left, or this module is leaving. Their data may already be gone, so a module should remember by id
## whatever it needs to undo. If a chunk leaves and comes straight back, its ids are removed and then added again.
func _markers_removed(_ids: PackedInt64Array) -> void:
	pass


# GDScript note: Godot calls _notification on every level of a class's inheritance, while a function like
# _enter_tree only runs at the lowest level unless it calls super(). Joining from here means a subclass can write
# its own _enter_tree or _exit_tree and can't accidentally stop the module from registering.
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		NavWorld.add_module(self)
	elif what == NOTIFICATION_EXIT_TREE:
		NavWorld.remove_module(self)
