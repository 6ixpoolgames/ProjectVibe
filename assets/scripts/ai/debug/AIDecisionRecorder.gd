# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## Records every AI decision of every pawn, with what it was made from, and saves them to a file.
##
## Debug tooling, like [AIDebugTimeline]: nothing in the game needs it. It listens through
## [member AIBehaviourManager.decision_listener] and keeps each [AIDecisionRecord], and, once for each pawn, a description of its
## brain: the settings of its behaviour manager and of each behaviour. Together they are everything a second decider needs to make
## the same decisions, which is how the planned C++ decider is checked against this one (scaling spec 6.2, "shadow mode").
## [br]
## Only one recorder listens at a time: starting one replaces any other listener.
## [br]
## How to use it ([code]mass_battle_measure -- --record-decisions=<file>[/code] does):
## [codeblock]
## var recorder := AIDecisionRecorder.new()
## add_child(recorder)
## recorder.start()
## # ... play ...
## recorder.stop()
## recorder.save("user://decisions.jsonl")   # one JSON object a line: the brains first, then the decisions
## print(recorder.summary())
## [/codeblock]
# REFACTOR: a second recording mechanism beside ReplayRecorder, the one place that records everything for every pawn. The records
# could be a replay channel (off by default, as they're heavy), saved in the replay file with the rest (reusable). See
# ai/CHANGELOG.md.
class_name AIDecisionRecorder
extends Node

## The most decisions kept. Once full, it stops keeping new ones and counts them in [member dropped], so a long run can't use up
## memory. 600 pawns deciding four times a second fill 200 000 in about 80 seconds.
@export_range(1000, 10000000, 1000, "or_greater") var max_records := 200000

## Decisions not kept because [member max_records] was reached.
var dropped := 0

var _records: Array[AIDecisionRecord] = []
var _brains := {} # pawn number -> Dictionary, see AIBehaviourManager.describe()
var _recording := false


## Starts listening to every pawn's decisions.
func start() -> void:
	AIBehaviourManager.decision_listener = _on_decision
	_recording = true


## Stops listening. What was recorded is kept.
func stop() -> void:
	# Only clear the listener if it's still this recorder's, so stopping an old one doesn't silence a newer one.
	if AIBehaviourManager.decision_listener == Callable(self, &"_on_decision"):
		AIBehaviourManager.decision_listener = Callable()
	_recording = false


## True while listening.
func is_recording() -> bool:
	return _recording


## Forgets everything recorded.
func clear() -> void:
	_records.clear()
	_brains.clear()
	dropped = 0


## Every decision kept, oldest first.
func get_records() -> Array[AIDecisionRecord]:
	return _records


## The brain description of the pawn with this number (see [method AIBehaviourManager.describe]), or an empty Dictionary.
func get_brain(pawn_number: int) -> Dictionary:
	return _brains.get(pawn_number, {})


## Counts, for a quick look: decisions, how many changed the running behaviour, how many the interrupt rule kept, each cause, each
## choice, how many is_available() calls and scores the decisions needed, and how many were dropped.
func summary() -> Dictionary:
	var causes := {}
	var chosen := {}
	var changed := 0
	var kept := 0
	var checks := 0
	var scored := 0
	for record in _records:
		causes[String(record.cause)] = causes.get(String(record.cause), 0) + 1
		chosen[String(record.chosen)] = chosen.get(String(record.chosen), 0) + 1
		changed += 1 if record.changed() else 0
		kept += 1 if record.kept_by_interrupt else 0
		for entry in record.behaviours:
			checks += 1 if entry.get("available", -1) >= 0 else 0
			scored += 1 if entry.get("score") != null else 0
	return {"decisions": _records.size(), "pawns": _brains.size(), "changed": changed, "kept_by_interrupt": kept,
		"availability_checks": checks, "scores": scored, "causes": causes, "chosen": chosen, "dropped": dropped}


## Writes everything to a file, one JSON object a line: first a {"kind": "brain"} line for each pawn, then a {"kind": "decision"}
## line for each decision, oldest first. Returns OK, or the error opening the file.
func save(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	for pawn_number: int in _brains:
		var brain: Dictionary = _brains[pawn_number].duplicate()
		brain["kind"] = "brain"
		file.store_line(JSON.stringify(brain, "", true, true)) # full precision, so numbers read back exactly
	for record in _records:
		var line := record.to_dict()
		line["kind"] = "decision"
		file.store_line(JSON.stringify(line, "", true, true))
	file.close()
	return OK


func _on_decision(record: AIDecisionRecord, manager: AIBehaviourManager) -> void:
	if not _brains.has(record.pawn_number):
		_brains[record.pawn_number] = manager.describe()
	if _records.size() >= max_records:
		dropped += 1
		return
	_records.append(record)


func _exit_tree() -> void:
	stop() # never leave a listener pointing at a freed recorder
