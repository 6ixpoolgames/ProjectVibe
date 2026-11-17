# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## The base for code that acts on nav markers (nav spec 21.4).
##
## Markers are plain data; a module is a node you add to a level that wants that behaviour, and a marker with no module does nothing.
## Extend this class, list your types in [method handled_types] and fill in the calls you need:
## [codeblock]
## class_name MyLadderModule extends NavMarkerModule
## func handled_types() -> Array[Script]: return [NavLink]
## func _markers_added(ids: PackedInt64Array) -> void: ...
## [/codeblock]
## Calls arrive during the tick, once per batch, with a list of ids. A late module gets every matching marker on the next tick.
## Subclasses of a handled type are handled too, and several modules can handle one type. A leaving module gets a final
## [method _markers_removed] at once, so it can undo what it did; the markers stay registered.
class_name NavMarkerModule
extends Node


## Announces which types this module works on. NavMarkerManager asks once, when the module joins.
## Return [NavMarker] to get every kind of marker.
func handled_types() -> Array[Script]:
	return []


## Whether this module counts as handling its types in the debug report. Tools that only look at markers, like
## NavMarkerDebugModule, return false, or a debug drawing would hide that nothing actually acts on them.
func counts_for_report() -> bool:
	return true


## Markers arrived. NavMarkerManager.get_marker(id) gives their full data.
func _markers_added(_ids: PackedInt64Array) -> void:
	pass


## Markers were switched on or off. NavMarkerManager.is_marker_enabled(id) gives the new state.
func _markers_changed(_ids: PackedInt64Array) -> void:
	pass


## Markers left, or this module is leaving. Their data may already be gone, so a module should remember by id
## whatever it needs to undo. If a chunk leaves and comes straight back, its ids are removed and then added again.
func _markers_removed(_ids: PackedInt64Array) -> void:
	pass


# Runs at every level of inheritance, so a subclass can write its own _enter_tree or _exit_tree without stopping the module joining.
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		NavMarkerManager.add_module(self)
	elif what == NOTIFICATION_EXIT_TREE:
		NavMarkerManager.remove_module(self)
