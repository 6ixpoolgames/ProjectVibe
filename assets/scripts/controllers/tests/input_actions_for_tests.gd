# Written by Claude (claude-opus-5-5), 2026-11-28. History: controllers/CHANGELOG.md.
## Test hooks for [InputActions], kept out of the shipping class: forget the list, or use another one instead of the file. Tests
## preload it: [code]const TestActions := preload("res://assets/scripts/controllers/tests/input_actions_for_tests.gd")[/code].
extends InputActions


## Forgets everything, so the next use reads the list again.
static func reset() -> void:
	_index_of.clear()
	_actions.clear()
	_warned.clear()
	_loaded = false


## Uses this list instead of the file.
static func use_list(actions: Array) -> void:
	reset()
	_loaded = true
	for action in actions:
		_add(_clean(action), false)
