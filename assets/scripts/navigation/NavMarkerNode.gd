## Written by Claude (claude-opus-5-5), 2026-11-06: places a nav marker by hand in a scene (nav spec section 21.5).
## Add this node, choose a marker type in the inspector, and fill in its values. The node's position and rotation
## say where the marker is. Generators skip this node and register their markers directly.
##
## What it does:
##   - On entering the scene, it makes its own copy of the marker and registers that. Without the copy, every
##     instance of a scene would share one marker, so opening one door would open them all.
##   - On leaving the scene, it removes the marker.
##
## What happens in odd cases (all checked in tests/nav_marker_node_selftest.gd):
##   - No marker set, or an undeclared tag: an inspector warning. At runtime it registers nothing, and the game runs.
##   - A marker's id comes from this node's scene path, so moving or renaming the node changes the id.
##     A node with an automatic name, which starts with @, may get a different id on each machine, so it warns.
##   - Moving the node after it has registered doesn't move the marker.
##
# GDScript note: @tool makes a script run inside the editor as well as in the game. It's needed here for the
# inspector warnings, so the code below is careful to do its game work only when the game is running.
@tool
class_name NavMarkerNode
extends Node3D

## The marker this node places. Pick a type such as NavLink or NavPoint from the inspector's list.
# GDScript note: a "set" block runs whenever the property is assigned, including from the inspector.
@export var marker: NavMarker:
	set(value):
		marker = value
		if is_inside_tree():
			update_configuration_warnings() # asks the editor to call _get_configuration_warnings again

var _marker_id := 0


## The registered marker's id, or 0 if nothing is registered.
func get_marker_id() -> int:
	return _marker_id


## Switches this node's marker on or off. The change takes effect on the next tick.
func set_marker_enabled(enabled: bool) -> void:
	if _marker_id != 0:
		NavWorld.set_enabled(_marker_id, enabled)


## What the editor shows as a warning triangle on this node. An empty list means no warning.
func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if marker == null:
		warnings.append("Choose a marker type in the inspector, or this node does nothing.")
		return warnings
	if Engine.is_editor_hint():
		NavTags.reset() # the declarations file may have been edited since the last check
	if marker.tag == &"":
		warnings.append("This marker has no tag, so it will be refused.")
	elif not NavTags.has_tag(marker.tag):
		warnings.append("The tag '%s' isn't declared in nav_tag_declarations.tres, so this marker will be refused." % marker.tag)
	return warnings


# GDScript note: as in NavMarkerModule, _notification runs at every level of inheritance, so a subclass with
# its own _enter_tree can't stop this. The editor check is what keeps this out of the scene you're editing.
func _notification(what: int) -> void:
	if Engine.is_editor_hint():
		return
	if what == NOTIFICATION_ENTER_TREE:
		_register()
	elif what == NOTIFICATION_EXIT_TREE:
		_unregister()


func _register() -> void:
	if marker == null:
		return
	if String(name).begins_with("@"):
		push_warning("[NavMarkerNode] %s has an automatic name, so machines may disagree on its marker's id. Give it a name of its own." % get_path())
	var copy: NavMarker = marker.duplicate()
	copy.place_at(global_transform)
	_marker_id = NavWorld.request_scene_marker(str(get_path()), copy)


func _unregister() -> void:
	if _marker_id != 0:
		NavWorld.remove_scene_marker(_marker_id)
		_marker_id = 0
