@tool
# Written by Claude (claude-opus-5-5), 2026-11-24. History: singletons/CHANGELOG.md.
## Shows the seconds beside every setting counted in ticks: a whole-number property whose name ends in [code]_ticks[/code], on any
## object, gets a TickSecondsProperty instead of the plain number field (pawn spec 16.1: settings are ticks at 60 a second).
extends EditorInspectorPlugin

const TickSecondsProperty := preload("res://addons/tick_seconds/TickSecondsProperty.gd")


func _can_handle(_object: Object) -> bool:
	return true


func _parse_property(_object: Object, type: Variant.Type, name: String, hint_type: PropertyHint, hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	if not handles(type, name):
		return false # the inspector's own editor
	add_property_editor(name, TickSecondsProperty.new(hint_type, hint_string))
	return true


## True for a property this plugin gives seconds to. Static, so the tests can check it outside the editor.
static func handles(type: Variant.Type, name: String) -> bool:
	return type == TYPE_INT and name.ends_with("_ticks")
