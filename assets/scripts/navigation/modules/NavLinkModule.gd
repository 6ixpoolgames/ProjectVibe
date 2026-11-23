# Written by Claude (claude-opus-5-5), 2026-11-08. History: navigation/CHANGELOG.md.
## Hands placed [NavLink] markers to nav, so paths can use them (nav spec 21.4 and 19, phase 3).
##
## Add it to a level that places links by hand, such as a jump between rooftops or a ladder. Links nav finds by itself at ledges and
## gaps (NavServer's auto_links setting) need nothing here. An enabled link becomes [code]NavServer.add_link[/code] with its start,
## end, two_way and press_action (its tile rebuilds a tick or two later); disabled, removed, or this module leaving removes it.
## [br]
## A link only works while nav is built at both ends: Detour joins the far end when that tile loads, so a link into unloaded ground
## is unused until it is. Not used yet: a link's extra_cost (links cost their length). Without NavServer (no navcore library) it
## does nothing.
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


# REFACTOR: the same lookup is written out in NavigationManager, BodyNavFeeder, NavDebugView, TerrainNavFeeder (four places) and
# CrowdMover; one shared helper would do (navigation/CHANGELOG.md).
func _nav_server() -> Object:
	if Engine.has_singleton(&"NavServer"):
		return Engine.get_singleton(&"NavServer")
	return null
