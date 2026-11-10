@tool
## Written by Claude (claude-opus-5-5), 2026-11-10: the Tag Picker editor plugin, the owner's request (typo protection for tags). It
## only adds TagInspectorPlugin to the inspector; that does the work. Editor only: nothing here runs in the game.
##
## Turn it on in Project > Project Settings > Plugins > Tag Picker.
## GDScript note: @tool makes a script run in the editor. It has to be the first line.
extends EditorPlugin

var _inspector_plugin: EditorInspectorPlugin = null


func _enter_tree() -> void:
	_inspector_plugin = preload("res://addons/tag_picker/TagInspectorPlugin.gd").new()
	add_inspector_plugin(_inspector_plugin)


func _exit_tree() -> void:
	if _inspector_plugin:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
