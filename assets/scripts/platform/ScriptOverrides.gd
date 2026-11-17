# Written by Claude (claude-opus-5-5), 2026-11-17. History: platform/README.md.
## Whether a script overrides a function of the script it extends: one place for a question several systems ask.
##
## The AbilityManager asks it to run only the abilities that have an every_tick() of their own, and which actions' readiness follows
## the body (can_start()); a behaviour, whether the C++ decider can judge it (is_available(), score()); the target selector, whether a
## game scores targets its own way (target_priority()). The answer is worked out once per script and function, and kept. It counts
## the entries of that name in the script's method list, which includes the scripts it extends: two or more means an override.
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
		_known[script] = answers # a Dictionary is shared, so filling it below fills the one kept here
	var known: Variant = answers.get(function_name)
	if known != null:
		return known
	var count := 0
	for method in script.get_script_method_list():
		if method["name"] == function_name:
			count += 1
	answers[function_name] = count > 1
	return count > 1
