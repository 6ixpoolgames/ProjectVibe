# Written by Claude (claude-opus-5-5), 2026-11-16. History: diagnostics/CHANGELOG.md.
## Catches the engine's warnings and errors for [DiagnosticsManager].
##
## So they go into the session log, the log panel (F8) and the replay, rate-limited. Godot calls a Logger for every push_warning,
## push_error and engine error.
## [br]
## Godot can call this from any thread (a worker that hits an error, say), so it only stores each message under a lock; the manager
## takes them on the main thread once a frame ([method take_messages]).
## [br]
## GDScript note: Logger is Godot's class for this (Godot 4.5 and later). OS.add_logger() starts calling it, OS.remove_logger() stops.
class_name DiagnosticsLogger
extends Logger

## The most messages held between two take_messages() calls. Past it, they're counted but not kept, so a flood can't fill memory.
const MAX_WAITING := 500

var _mutex := Mutex.new()
var _waiting: Array = [] # [level ("error", "warning", "script error", "shader error"), text, where]
var _dropped := 0


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int,
		_script_backtrace: Array[ScriptBacktrace]) -> void:
	# GDScript note: for push_warning and push_error, the message is in code and rationale is empty; for engine errors it's the other
	# way round, or both. Keep whichever says more.
	var text := rationale if rationale != "" else code
	if rationale != "" and code != "" and not rationale.contains(code):
		text = "%s (%s)" % [rationale, code]
	var level: String = ["error", "warning", "script error", "shader error"][clampi(error_type, 0, 3)]
	_mutex.lock()
	if _waiting.size() < MAX_WAITING:
		_waiting.append([level, text, "%s:%d %s" % [file.get_file(), line, function]])
	else:
		_dropped += 1
	_mutex.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass # print() output isn't collected: it isn't a warning, and samples print a lot


## The messages since the last call, and how many were dropped because too many came at once.
func take_messages() -> Array:
	_mutex.lock()
	var messages := _waiting
	var dropped := _dropped
	_waiting = []
	_dropped = 0
	_mutex.unlock()
	return [messages, dropped]
