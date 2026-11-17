# Written by Claude (claude-opus-5-5), 2026-11-17. History: platform/README.md.
## Whether a script overrides a function of the script it extends: one place for a question several systems ask.
##
## The AbilityManager asks it to run only the abilities that have an every_tick() of their own, and to know which actions' readiness
## follows the body (can_start()); a behaviour asks it to know whether the C++ decider can judge it (is_available(), score()); the
## target selector asks it whether a game scores targets its own way (target_priority()). The answer is worked out once per script and
## function, and kept.
## [br]
## GDScript note: a script's method list ([method Script.get_script_method_list]) includes the methods of the scripts it extends, and
## a function overridden lower down appears once for every script that defines it. So two or more entries with the name mean
## something overrode the base's own.
## [codeblock]
## ScriptOverrides.overrides(ability.get_script(), &"every_tick")   # true for Dash, false for Walk
## [/codeblock]
class_name ScriptOverrides
extends RefCounted

static var _known := {} # script -> {function name -> true or false}


## True if script, or a script between it and its base, overrides function_name. False for a null script, or a function only the
## base defines.
static func overrides(script: Script, function_name: StringName) -> bool:
	if script == null:
		return false
	var answers: Dictionary = _known.get(script, {})
	if answers.is_empty():
		_known[script] = answers # GDScript note: a Dictionary is shared, so filling it below fills the one kept here
	var known: Variant = answers.get(function_name)
	if known != null:
		return known
	var count := 0
	for method in script.get_script_method_list():
		if method["name"] == function_name:
			count += 1
	answers[function_name] = count > 1
	return count > 1
