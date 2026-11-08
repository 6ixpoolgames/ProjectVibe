## Written by Claude (claude-opus-5-5), 2026-11-08: hands placed NavLink markers to nav, so paths can use them (nav spec sections
## 21.4 and 19, phase 3). Add this node to a level that places links by hand, such as a jump between two rooftops or a ladder.
##
## Links nav finds by itself at ledges and gaps (NavServer's auto_links setting) need nothing here. This is only for the ones a
## designer marks, where the automatic search wouldn't find one, or where a link should press a different action.
##
## What it does with each NavLink marker:
##   - Enabled: calls NavServer.add_link with the marker's start, end, two_way and press_action. The tile holding the start
##     rebuilds to include it, a tick or two later.
##   - Disabled (NavMarkerManager.set_enabled), removed, or this module leaving the level: NavServer.remove_link.
##
## A link only works while nav is built at both ends. Detour joins its far end when that tile loads, so a link into ground that
## isn't loaded yet is simply not used until it is. Nothing here needs to watch for that.
##
## Not used yet: a NavLink's extra_cost. Links cost their length, like walking.
##
## What happens in odd cases (all checked in tests/nav_link_module_selftest.gd):
##   - No NavServer (the navcore library isn't loaded): it does nothing, and markers stay registered as usual.
##   - A marker switched on twice, or off when it was never on: nothing changes.
class_name NavLinkModule
extends NavMarkerModule

# Marker id -> the NavServer link id it made. Kept so this module undoes exactly what it did, and nothing else.
var _link_ids := {}


func handled_types() -> Array[Script]:
	return [NavLink]


## How many links this module has handed to nav right now.
func get_link_count() -> int:
	return _link_ids.size()


## The NavServer link id made for this marker, or 0 if there isn't one.
func get_link_id(marker_id: int) -> int:
	return _link_ids.get(marker_id, 0)


func _markers_added(ids: PackedInt64Array) -> void:
	for id in ids:
		if NavMarkerManager.is_marker_enabled(id):
			_add_link(id)


func _markers_changed(ids: PackedInt64Array) -> void:
	for id in ids:
		if NavMarkerManager.is_marker_enabled(id):
			_add_link(id)
		else:
			_remove_link(id)


func _markers_removed(ids: PackedInt64Array) -> void:
	for id in ids:
		_remove_link(id)


func _add_link(marker_id: int) -> void:
	var nav := _nav_server()
	if nav == null or _link_ids.has(marker_id):
		return
	var link := NavMarkerManager.get_marker(marker_id) as NavLink
	if link == null:
		return
	_link_ids[marker_id] = nav.add_link(link.position, link.get_end_position(), link.two_way, link.press_action)


func _remove_link(marker_id: int) -> void:
	if not _link_ids.has(marker_id):
		return
	var nav := _nav_server()
	if nav:
		nav.remove_link(_link_ids[marker_id])
	_link_ids.erase(marker_id)


func _nav_server() -> Object:
	# GDScript note: NavServer comes from the navcore C++ library, as an engine singleton. Without the library there's none.
	if Engine.has_singleton(&"NavServer"):
		return Engine.get_singleton(&"NavServer")
	return null
