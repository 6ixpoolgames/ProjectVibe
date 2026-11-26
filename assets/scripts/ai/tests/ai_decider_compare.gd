## Written by Claude (claude-opus-5-5), 2026-11-17: replays a saved decision recording through the C++ AIDecider and prints how
## many decisions agree with GDScript's, and what decide() cost (scaling spec 6.2, the shadow decider). Not pass/fail; the self-test
## (ai_decider_selftest) is. Record a fight first:
##   godot --headless --fixed-fps 60 --path . "res://assets/scripts/samples/tests/mass_battle_measure.tscn" -- --size=200 --spawn-distance=40 --record-decisions=<file>
## then compare it:
##   godot --headless --path . "res://assets/scripts/ai/tests/ai_decider_compare.tscn" -- --file=<file>
extends Node

const DecisionReplay := preload("res://assets/scripts/ai/tests/decision_replay.gd")


func _ready() -> void:
	var path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--file="):
			path = argument.trim_prefix("--file=")
	if path == "":
		print("--- give a recording: -- --file=<file> ---")
		get_tree().quit(1)
		return
	var started := Time.get_ticks_msec()
	var data := DecisionReplay.from_file(path)
	if data.has("error"):
		print("--- %s ---" % data["error"])
		get_tree().quit(1)
		return
	print("--- %d decisions by %d pawns, read in %.1f s ---" % [data["decisions"].size(), data["brains"].size(), (Time.get_ticks_msec() - started) / 1000.0])
	var result := DecisionReplay.compare(data)
	print(DecisionReplay.describe(result))
	for example: String in result["examples"]:
		print("  " + example)
	get_tree().quit(0 if result["agreed"] == result["decisions"] else 1)
