@tool
# Written by Claude (claude-opus-5-5), 2026-11-24. History: singletons/CHANGELOG.md.
## The Tick Seconds editor plugin: adds TickSecondsInspectorPlugin to the inspector, so every setting in ticks shows its seconds.
## Editor only: nothing here runs in the game. Turn it on in Project > Project Settings > Plugins > Tick Seconds.
extends EditorPlugin

var _inspector_plugin: EditorInspectorPlugin = null


func _enter_tree() -> void:
	_inspector_plugin = preload("res://addons/tick_seconds/TickSecondsInspectorPlugin.gd").new()
	add_inspector_plugin(_inspector_plugin)


func _exit_tree() -> void:
	if _inspector_plugin:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
