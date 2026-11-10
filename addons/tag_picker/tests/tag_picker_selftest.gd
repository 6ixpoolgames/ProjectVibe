## Written by Claude (claude-opus-5-5), 2026-11-10: headless self-test for the Tag Picker plugin's logic. The inspector parts
## themselves (EditorInspectorPlugin, EditorProperty) can only be made inside the editor, so this checks what they're built on: the
## scripts load, abilities are recognised, and a dropdown lists the declared tags with the right one selected, an undeclared value
## kept and marked, and "(none)" for no tag.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://addons/tag_picker/tests/tag_picker_selftest.tscn"
extends Node

const ABILITY_BASE_PATH := "res://assets/scripts/abilities/AbilityBase.gd"

var _failures := 0


func _ready() -> void:
	print("--- Tag picker self-test ---")
	var scripts_load := true
	for path in ["res://addons/tag_picker/TagPickerPlugin.gd", "res://addons/tag_picker/TagInspectorPlugin.gd", "res://addons/tag_picker/TagPickerProperty.gd"]:
		var script: Script = load(path)
		scripts_load = scripts_load and script != null and script.can_instantiate()
	_check(scripts_load, "the plugin's three scripts load")

	var inspector: Script = load("res://addons/tag_picker/TagInspectorPlugin.gd")
	var dash := DashAbility.new()
	var plain := Node.new()
	_check(inspector.extends_script(dash, ABILITY_BASE_PATH) and not inspector.extends_script(plain, ABILITY_BASE_PATH) and not inspector.extends_script(null, ABILITY_BASE_PATH), "it handles abilities (a DashAbility) and nothing else")

	# Claude 2026-11-10 (pawn spec 8.11): effects and their parts get dropdowns too, each from the right tag set.
	var effect := Effect.new()
	var priority_part := AbilityPriorityPart.new()
	var resistance_part := ResistancePart.new()
	var effect_props: Dictionary = inspector.properties_of(effect)
	_check(effect_props.has("tags") and effect_props["tags"] == [true, inspector.TagSet.EFFECT], "an Effect's tags: a list of effect tags")
	_check(inspector.properties_of(priority_part).get("ability_tag") == [false, inspector.TagSet.ABILITY] and inspector.properties_of(resistance_part).get("tag") == [false, inspector.TagSet.EFFECT], "an AbilityPriorityPart names an ability tag, a ResistancePart an effect tag")
	_check(inspector.properties_of(plain).is_empty() and inspector.properties_of(dash).has("locks_out"), "a plain node gets none, and abilities keep theirs")
	_check(EffectTags.read_declared_tags().has(EffectTags.DAMAGE_ELEMENTAL), "the effect tag dropdown offers parent levels too (damage.elemental)")

	var tags := TagRegistry.read_declared_tags()
	var property: Script = load("res://addons/tag_picker/TagPickerProperty.gd")
	var single: OptionButton = property.make_picker(tags, &"movement.dash", true)
	_check(single.item_count == tags.size() + 1 and single.get_item_metadata(single.selected) == &"movement.dash", "one tag: (none) plus every declared tag, with the current one selected (%d items)" % single.item_count)
	var misspelt: OptionButton = property.make_picker(tags, &"movment.dash", true)
	_check(misspelt.get_item_text(misspelt.selected).ends_with("(not declared)") and misspelt.get_item_metadata(misspelt.selected) == &"movment.dash", "an undeclared value is kept and marked, not lost (%s)" % misspelt.get_item_text(misspelt.selected))
	var empty: OptionButton = property.make_picker(tags, &"", true)
	_check(empty.selected == 0 and empty.get_item_metadata(0) == &"", "no tag: (none) is selected")
	var in_list: OptionButton = property.make_picker(tags, &"combat", false)
	_check(in_list.item_count == tags.size() and in_list.get_item_metadata(in_list.selected) == &"combat", "a list entry: no (none), parent levels are offered (combat)")

	for node in [dash, plain, single, misspelt, empty, in_list]:
		node.free()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
