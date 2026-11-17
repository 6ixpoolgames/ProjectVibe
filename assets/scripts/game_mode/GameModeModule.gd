# Written by Claude (claude-opus-5-5), 2026-11-07. History: game_mode/CHANGELOG.md.
## The base for one optional piece of a game's rules, added to GameMode.
##
## Extend it, and override what's useful. A module with no per-frame work should switch off its own _process, because Godot runs it
## for any script that defines it.
class_name GameModeModule
extends Node


## Just added. Fill in your line on GameMode here, if you have one, such as game_mode.ai_activation_manager = self.
func _on_module_added(_game_mode: GameModeSingleton) -> void:
	pass


## About to be removed. Clear your line on GameMode here, and undo anything you've changed in the world.
func _on_module_removed(_game_mode: GameModeSingleton) -> void:
	pass


## The names of this module's settings a start menu may offer before a match.
##
## Each is a property of this module (an @export, so its range and type show). MatchOptionsPanel.add_from_game_mode() lists them for
## every module the game has. Empty: none.
func get_match_options() -> PackedStringArray:
	return PackedStringArray()
