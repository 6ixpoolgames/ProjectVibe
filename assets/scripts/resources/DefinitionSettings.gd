# Written by Claude (claude-opus-5-5), 2026-11-25. History: resources/CHANGELOG.md.
## Works out the settings a node runs with: its definition (or its kind's defaults), with the node's own changes on top.
##
## [AbilityBase] and [AIBehaviourBase] each hold one, so both read and write settings the same way (pawn spec 16.3). A node's kind gives
## its defaults ([code]make_default_definition()[/code], made once per script and shared); its definition picks a shared file; a
## setting written on the node goes into a variant of its own based on that (its script's _init(), values a scene sets,
## [method make_own]). While playing, writing a shared definition is an error: every pawn using it would change.
class_name DefinitionSettings
extends RefCounted

## True if the last [method resolve] was given a definition of another kind, so the node runs with its kind's defaults.
var fell_back := false
## The node's own variant, on top of its definition: what was written on the node. Null: none.
var own: Definition = null

var _node: Node
static var _defaults_by_script := {} # node script -> its kind's defaults
static var _names_by_script := {} # node script -> {setting name: true}


func _init(node: Node) -> void:
	_node = node


## The node's kind's defaults: [code]make_default_definition()[/code], made once per script and shared by every node of the kind.
func kind_defaults() -> Definition:
	var script: Script = _node.get_script()
	var found: Definition = _defaults_by_script.get(script)
	if found == null:
		found = _node.call(&"make_default_definition")
		_defaults_by_script[script] = found
	return found


## The settings to run with: definition worked out ([method Definition.resolved]), or the kind's defaults when it's empty or of another
## kind (a warning), with [member own] on top.
func resolve(definition: Definition) -> Definition:
	var defaults := kind_defaults()
	var base := definition
	fell_back = false
	if base and not fits(base, defaults):
		push_warning("%s: its definition %s is for another kind; it runs with the %s defaults." % [_describe(), base.describe(), defaults.get_script().get_global_name()])
		fell_back = true
		base = null
	var chosen: Definition = base if base else defaults
	if own:
		own.based_on = chosen # its own changes on top of the definition, or of the kind's defaults
		chosen = own
	return chosen.resolved()


## Writes a setting into [member own], made on first use. With locked on (the node is set up and playing) and no own variant yet, it's
## an error and nothing is written. Returns true if it wrote it; the node then resolves its settings again.
func write(definition: Definition, setting: StringName, value: Variant, locked: bool) -> bool:
	if own == null:
		if locked:
			push_error("%s: %s comes from its definition, which every pawn using it shares; give it another with use_definition(), or its own copy with make_definition_unique()." % [_describe(), setting])
			return false
		own = _new_own(definition)
	# A typed list setting (Array[StringName]) refuses a plain list through set(), so the value takes the setting's own array type.
	var current: Variant = own.get(setting)
	if value is Array and current is Array and (current as Array).is_typed() and not (value as Array).is_typed():
		var typed: Array = (current as Array).duplicate()
		typed.assign(value)
		value = typed
	own.set(setting, value)
	return true


## Makes [member own] if there isn't one, so settings can be written while playing (Godot's "Make Unique"). Returns it.
func make_own(definition: Definition) -> Definition:
	if own == null:
		own = _new_own(definition)
	return own


## True if the node's kind has a setting of this name: what the node's _get and _set route to its settings.
func has_setting(setting: StringName) -> bool:
	var script: Script = _node.get_script()
	var names: Variant = _names_by_script.get(script)
	if names == null:
		names = {}
		for found in kind_defaults().setting_names():
			names[StringName(found)] = true
		_names_by_script[script] = names
	return names.has(setting)


## What to check about where the settings come from, for diagnostics: "fell back" (a definition of another kind), "embedded" (saved in
## a scene, a prototype tweak), "own settings" (written on the node), or "" for a definition file or the kind's defaults.
func note(definition: Definition) -> String:
	if fell_back:
		return "fell back"
	if definition and definition.is_embedded():
		return "embedded"
	if own:
		return "own settings"
	return ""


## True if chosen is of the defaults' class, or a class built on it.
static func fits(chosen: Definition, defaults: Definition) -> bool:
	var script: Script = chosen.get_script()
	var wanted: Script = defaults.get_script()
	while script:
		if script == wanted:
			return true
		script = script.get_base_script()
	return false


# Its own variant, of the definition's class, based on the definition (or the kind's defaults) from the start, so what's written on it
# counts as changed.
func _new_own(definition: Definition) -> Definition:
	var defaults := kind_defaults()
	var base: Definition = definition if definition and fits(definition, defaults) else defaults
	var made: Definition = base.get_script().new()
	made.based_on = base
	return made


func _describe() -> String:
	if _node.has_method(&"_describe_node"):
		return "[%s] %s" % [_node.get_script().get_global_name(), _node.call(&"_describe_node")]
	return "[%s] %s" % [_node.get_script().get_global_name(), _node.name]
