# Written by Claude (claude-opus-5-5), 2026-11-24: headless self-test for the Tick Seconds plugin's logic. The inspector parts
# (EditorInspectorPlugin, EditorProperty) can only be made inside the editor, so this checks what they're built on: the scripts load,
# which properties get seconds, the seconds text and the range hint.
# Exits 0 on success, 1 on failure. Run from the project folder:
#   godot --headless --path . "res://addons/tick_seconds/tests/tick_seconds_selftest.tscn"
extends Node

var _failures := 0


func _ready() -> void:
	print("--- Tick seconds self-test ---")
	var scripts_load := true
	for path in ["res://addons/tick_seconds/TickSecondsPlugin.gd", "res://addons/tick_seconds/TickSecondsInspectorPlugin.gd", "res://addons/tick_seconds/TickSecondsProperty.gd"]:
		var script: Script = load(path)
		scripts_load = scripts_load and script != null
	_check(scripts_load, "the plugin's three scripts load")

	var inspector: Script = load("res://addons/tick_seconds/TickSecondsInspectorPlugin.gd")
	_check(inspector.handles(TYPE_INT, "cooldown_ticks") and not inspector.handles(TYPE_FLOAT, "cooldown_ticks") and not inspector.handles(TYPE_INT, "max_charges"), "whole-number settings ending in _ticks get seconds; others don't")

	var property: Script = load("res://addons/tick_seconds/TickSecondsProperty.gd")
	_check(property.seconds_text(30) == "0.5 s" and property.seconds_text(60) == "1 s" and property.seconds_text(0) == "0 s" and property.seconds_text(8) == "0.13 s", "seconds at 60 a second: 30 is 0.5 s, 60 is 1 s, 8 is 0.13 s (%s)" % property.seconds_text(8))
	_check(property.seconds_text(-1) == "", "a negative count (never, or use another setting) shows no seconds")
	var limits: Dictionary = property.range_of(PROPERTY_HINT_RANGE, "0,600,1,or_greater")
	_check(limits["min"] == 0.0 and limits["max"] == 600.0 and limits["or_greater"] and not limits["or_less"], "a range hint sets the limits")
	var open: Dictionary = property.range_of(PROPERTY_HINT_NONE, "")
	_check(open["or_less"] and open["or_greater"], "no range hint: open both ways")

	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
