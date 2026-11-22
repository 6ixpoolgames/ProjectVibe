@tool
## Written by Claude (claude-opus-5-5), 2026-11-10: swaps the inspector's text fields for tag dropdowns on abilities. For an ability
## (any script that extends AbilityDefinition, where the settings live) it replaces the editors of the properties in TAG_PROPERTIES with a TagPickerProperty, which
## offers the tags the declarations files declare (TagRegistry.read_declared_tags), with their parent levels.
##
## To give another class tag dropdowns: add its script and its tag properties to HANDLED.
## Claude 2026-11-10 (pawn spec 8.11): effects too. HANDLED lists each script with its tag properties and which categories each
## offers. An Effect's tags and a ResistancePart's tag are effect tags; an AbilityPriorityPart's ability_tag is an ability tag.
## Claude 2026-11-22 (tag spec 2): one registry; each property names the categories its dropdown offers. Nav markers get dropdowns too. Parts are edited inside their Effect in the inspector, and get dropdowns there.
extends EditorInspectorPlugin

const TagPickerProperty := preload("res://addons/tag_picker/TagPickerProperty.gd")
const ABILITY_DEFINITION_PATH := "res://assets/scripts/abilities/definitions/AbilityDefinition.gd"

## Claude 2026-11-22: the categories a dropdown offers.
const ABILITY: Array[StringName] = [&"ability"]
const EFFECT: Array[StringName] = [&"effect"]
const NAV: Array[StringName] = [&"nav"]

## Claude 2026-11-10: script path -> {property: [is a list, the categories it offers]}. A script that extends one of these gets its
## dropdowns.
const HANDLED := {
	ABILITY_DEFINITION_PATH: {"category": [false, ABILITY], "extra_categories": [true, ABILITY], "locks_out": [true, ABILITY], "cancelled_by": [true, ABILITY]},
	"res://assets/scripts/effects/Effect.gd": {"tags": [true, EFFECT]},
	"res://assets/scripts/effects/parts/ResistancePart.gd": {"tag": [false, EFFECT]},
	"res://assets/scripts/effects/parts/AbilityPriorityPart.gd": {"ability_tag": [false, ABILITY]},
	"res://assets/scripts/navigation/markers/NavMarker.gd": {"tag": [false, NAV]},
}


func _can_handle(object: Object) -> bool:
	return not properties_of(object).is_empty()


func _parse_property(object: Object, type: Variant.Type, name: String, hint_type: PropertyHint, hint_string: String, usage_flags: int, wide: bool) -> bool:
	var properties := properties_of(object)
	if not properties.has(name):
		return false # the inspector's own editor
	var is_list: bool = properties[name][0]
	var tags := TagRegistry.read_declared_tags(properties[name][1])
	add_property_editor(name, TagPickerProperty.new(is_list, tags))
	return true # replaces the inspector's own editor


## Claude 2026-11-10: the tag properties this object has, from HANDLED, or {} for an object this plugin leaves alone. Static, so the
## tests can check it outside the editor.
static func properties_of(object: Object) -> Dictionary:
	for path: String in HANDLED:
		if extends_script(object, path):
			return HANDLED[path]
	return {}


## True if the object's script is this one or extends it. Compared by path, so it works whether or not the ability's script runs in
## the editor (abilities aren't @tool: the editor holds a stand-in that still knows its script). Static, so the tests can check it
## outside the editor.
static func extends_script(object: Object, path: String) -> bool:
	var script: Script = object.get_script() if object else null
	while script:
		if script.resource_path == path:
			return true
		script = script.get_base_script()
	return false
