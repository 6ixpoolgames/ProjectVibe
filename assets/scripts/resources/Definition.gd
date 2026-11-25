# Written by Claude (claude-opus-5-5), 2026-11-21. History: resources/CHANGELOG.md.
@tool
## Settings shared by everything that uses them, with variants: the base of [AbilityDefinition] and [ProjectileDefinition] (ability
## spec 3).
##
## A subclass declares its settings as exported properties whose setters call [method _changed]. [member based_on] makes one a variant:
## each setting it hasn't changed comes from its base, so changing the base changes its variants. In the inspector a variant shows its
## base's values, and the revert arrow on a changed one goes back to following the base. Read-only while playing: what uses it runs with
## [method resolved], the copy with every setting worked out.
class_name Definition
extends Resource

## The settings this variant has changed from its base: set as they're edited, and saved with it. Only these are saved in a variant's
## file; the rest follow the base.
@export_storage var changed_values := PackedStringArray()
## The definition this one is a variant of. Empty: one of its own, starting from the kind's defaults.
@export var based_on: Definition:
	set(value):
		based_on = value
		_resolved = null
		if Engine.is_editor_hint():
			_show_base_values()
			notify_property_list_changed()

## For a resolved copy: the definition it was worked out from. Null on a definition of its own.
var resolved_from: Definition:
	get:
		return _resolved_from.get_ref() if _resolved_from else null
	set(value):
		_resolved_from = weakref(value) if value else null
# Weak: the definition keeps its resolved copy (_resolved), so a strong link back would be a cycle neither is ever freed from.
var _resolved_from: WeakRef = null
var _resolved: Definition = null
var _copying_base := false # setting values from the base, which doesn't change them
# Each script's setting names, worked out once.
static var _setting_names_by_script := {}
# How many bases deep value_of may go: a base that leads back to itself is an error, not a hang.
const MAX_BASE_DEPTH := 32


# A kind's definition sets its defaults in its own _init(), after calling this.
func _init() -> void:
	pass


## The names of its settings: what a variant can change.
func setting_names() -> PackedStringArray:
	var script: Script = get_script()
	var names: Variant = _setting_names_by_script.get(script)
	if names == null:
		var found := PackedStringArray()
		for property in get_property_list():
			var usage: int = property["usage"]
			if usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR and property["name"] != "based_on":
				found.append(property["name"])
		_setting_names_by_script[script] = found
		names = found
	return names


## A setting's value here: its own if it changed it or has no base, else its base's.
func value_of(setting: StringName, depth := 0) -> Variant:
	if based_on == null or changed_values.has(setting) or not setting in based_on:
		return get(setting)
	if depth >= MAX_BASE_DEPTH:
		push_error("[Definition] %s: its bases lead back to themselves; using its own value of %s." % [describe(), setting])
		return get(setting)
	return based_on.value_of(setting, depth + 1)


## This definition with every setting worked out, the copy an ability runs with: itself when it has no base. Worked out once while
## playing (definitions don't change then), every time in the editor.
func resolved() -> Definition:
	if based_on == null:
		return self
	if _resolved and not Engine.is_editor_hint():
		return _resolved
	if not _base_fits():
		push_warning("[Definition] %s is based on %s, a different kind; only the settings both have follow it." % [describe(), based_on.describe()])
	var out: Definition = get_script().new()
	out._copying_base = true
	for setting in setting_names():
		out.set(setting, value_of(setting))
	out._copying_base = false
	out.resource_name = resource_name
	out.resolved_from = self
	_resolved = out
	return out


## A short name for warnings and readouts: its resource_name, its file's name, or the kind.
func describe() -> String:
	if resource_name != "":
		return resource_name
	if resource_path != "" and not resource_path.contains("::"):
		return resource_path.get_file().get_basename()
	if resource_path.contains("::"):
		return "%s (embedded in %s)" % [get_script().get_global_name(), resource_path.get_slice("::", 0).get_file()]
	return "%s (made in code)" % get_script().get_global_name()


## True if it's saved inside a scene ("Make Unique"), not in a file of its own: a quick tweak while prototyping. Diagnostics lists them.
func is_embedded() -> bool:
	return resource_path.contains("::")


# Each setting's setter calls this. A variant keeps the settings changed from its base; set back to the base's value (the revert arrow
# does that), it follows the base again. Without a base nothing is kept: every value is its own, including the kind's defaults its
# _init() sets. So give a variant its base first, then change what differs.
func _changed(setting: StringName, value: Variant) -> void:
	_resolved = null
	if _copying_base or based_on == null:
		return
	var at := changed_values.find(setting)
	if Engine.is_editor_hint() and value == based_on.value_of(setting):
		if at >= 0:
			changed_values.remove_at(at)
			notify_property_list_changed()
	elif at < 0:
		changed_values.append(setting)
		if Engine.is_editor_hint():
			notify_property_list_changed()


# In the editor, a variant shows its base's values for the settings it hasn't changed.
func _show_base_values() -> void:
	if based_on == null:
		return
	_copying_base = true
	for setting in setting_names():
		if not changed_values.has(setting) and setting in based_on:
			set(setting, based_on.value_of(setting))
	_copying_base = false


# True if the base is the same kind, or one this kind is built on (a SprintDefinition based on a WalkDefinition).
func _base_fits() -> bool:
	var script: Script = get_script()
	var base_script: Script = based_on.get_script()
	while script:
		if script == base_script:
			return true
		script = script.get_base_script()
	return false


# A variant saves only the settings it changed; the rest follow its base.
func _validate_property(property: Dictionary) -> void:
	var usage: int = property["usage"]
	if based_on and usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR and property["name"] != "based_on" \
			and not changed_values.has(property["name"]):
		property["usage"] = usage & ~PROPERTY_USAGE_STORAGE


func _property_can_revert(property: StringName) -> bool:
	return based_on != null and changed_values.has(property)


func _property_get_revert(property: StringName) -> Variant:
	return based_on.value_of(property) if based_on else null
