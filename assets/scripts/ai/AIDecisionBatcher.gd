# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## Gathers the AI's behaviour decisions into one batch a tick for the C++ decider (AIBatchDecider), and, in shadow mode, checks its
## answers against GDScript's without using them.
##
## A GameMode module ([code]GameMode.get_module(AIDecisionBatcher)[/code]), off by default. Scaling spec 6.2: decisions made
## together in C++, later on the worker threads, instead of one pawn at a time in GDScript. C++ is to be the main path, with
## GDScript's decider a dormant backup (the owner's call); until the batch's answers are used (spec step 5e), it only checks them.
## [br]
## Modes:
## [br]- OFF: nothing happens, and the AI pays one check per decision.
## [br]- SHADOW: every decision still runs in GDScript, unchanged. As each one starts, this module gathers the pawn's inputs from the
##   live pawn into a row (its brain, state, target, running behaviour, the hard-rule bitmasks, persistence, and its AI inputs,
##   [AIInputs], which C++ checks the behaviours' conditions against), and notes GDScript's answer when it ends. At the end of the tick, one C++
##   call decides every row, and the answers are compared. Disagreements are counted and the first few logged as warnings
##   ([method get_counts]). The game plays exactly as with OFF.
## [br]
## What it costs is timed ([PerfScopes]): [code]ai.batch.gather[/code] (building each row in GDScript), [code]ai.batch.build[/code]
## (the tick's arrays), [code]ai.batch.decide[/code] (the C++ call) and [code]ai.batch.compare[/code].
## [br]
## A brain is described once per behaviour manager ([method AIBehaviourManager.describe]); pawns with the same behaviour set share one.
## A setting changed during play after that (set_score_jitter, say) isn't seen, and would show as disagreements.
## [br]
## Behaviours judged by their conditions (every built-in one) cost C++ nothing more than the inputs. A behaviour with its own
## is_available() or score() code ([method AIBehaviourBase.has_own_code]) can't be read by C++, so it's asked in GDScript, for every
## such behaviour that passes the hard rules, before GDScript's own decision asks it at the same tick. That code must be safe to call
## more than once a tick, with no effect on the game.
class_name AIDecisionBatcher
extends GameModeModule

## What the batcher does. See the class description.
enum Mode {
	OFF, ## nothing
	SHADOW, ## decides beside GDScript and compares, without using its answers
}

## What it does: OFF or SHADOW.
@export var mode := Mode.OFF:
	set(value):
		mode = value
		_apply_mode()
## How many disagreements are logged as warnings, with what each side chose. The rest are only counted.
@export_range(0, 100, 1, "or_greater") var warnings_kept := 5

var _decider: Object = null # the C++ AIBatchDecider, made when shadow mode starts
var _brain_of_manager := {} # behaviour manager instance id -> brain number
var _brain_by_text := {} # a brain's shared description as text -> brain number
var _state_numbers: Array = [] # brain number -> {state name -> the decider's state number}
var _connected := false

# This tick's rows, one per decision, as parallel arrays (the columns AIBatchDecider.decide() takes).
var _brain := PackedInt32Array()
var _pawn := PackedInt64Array()
var _seed := PackedInt64Array()
var _tick := PackedInt64Array()
var _state := PackedInt32Array()
var _has_target := PackedByteArray()
var _normal := PackedByteArray()
var _priority := PackedInt32Array()
var _running := PackedInt32Array()
var _started := PackedInt64Array()
var _cooling := PackedInt64Array()
var _can_press := PackedInt64Array()
var _known := PackedInt64Array()
var _available := PackedInt64Array()
var _persistence_rows: Array[PackedFloat64Array] = [] # per row, one value per behaviour; flattened at the end of the tick
var _score_rows: Array[PackedFloat64Array] = []
var _input_rows: Array[PackedFloat64Array] = [] # per row, the pawn's AI inputs; flattened at the end of the tick
var _answers := PackedInt32Array() # GDScript's choice per row: a slot, -1 for nothing, -2 not noted yet
var _names: Array[StringName] = [] # each row's pawn, for warnings

var _counts := {"decisions": 0, "agreed": 0, "differs": 0, "unanswered": 0, "batches": 0, "largest_batch": 0}


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _on_module_removed(_game_mode: GameModeSingleton) -> void:
	mode = Mode.OFF


func get_match_options() -> PackedStringArray:
	return PackedStringArray(["mode"])


## The counts so far: decisions (rows decided in C++), agreed, differs, unanswered (a row GDScript never finished, which shouldn't
## happen), batches (C++ calls), largest_batch (most rows in one), and examples (the disagreements logged).
func get_counts() -> Dictionary:
	return _counts.duplicate(true)


## Starts the counts afresh.
func reset_counts() -> void:
	_counts = {"decisions": 0, "agreed": 0, "differs": 0, "unanswered": 0, "batches": 0, "largest_batch": 0}


# --- Called by AIBehaviourManager.decide() while this is its decision_batcher ---


## Gathers one decision's inputs from the live pawn, before GDScript decides. Returns the row, or -1 if the pawn can't be batched (its
## brain has more behaviours than the decider takes).
func gather(manager: AIBehaviourManager, behaviours: Array[AIBehaviourBase], running: AIBehaviourBase, tick: int, event_priority: int,
		event_is_normal: bool) -> int:
	var started := PerfScopes.begin()
	var brain := _brain_for(manager)
	if brain < 0:
		return -1
	var context := manager.pawn.ai_context
	var state_name := context.current_state_name()
	var states: Dictionary = _state_numbers[brain]
	var state_number: Variant = states.get(state_name)
	if state_number == null:
		state_number = _decider.find_state(brain, state_name)
		states[state_name] = state_number
	var has_target := context.has_target()
	var abilities := manager.pawn.ability_manager
	var cooling := 0
	var can_press := -1 # every action could start, unless found otherwise
	var known := 0
	var available := 0
	var persistence := PackedFloat64Array()
	var scores := PackedFloat64Array()
	persistence.resize(behaviours.size())
	scores.resize(behaviours.size())
	# The hard rules, as AIBehaviourManager.decide() applies them, then each remaining behaviour's own answers.
	# REFACTOR: this loop repeats the manager's own rule loop for every behaviour (allowed state, cooldown, target, action,
	# persistence), most of a row's cost. Each pawn's decision state kept in C++ (scaling spec 6.2, step 5c) removes it (efficient).
	# See CHANGELOG.md.
	for slot in behaviours.size():
		var behaviour := behaviours[slot]
		var bit := 1 << slot
		persistence[slot] = behaviour.persistence_now(tick)
		scores[slot] = NAN
		if not behaviour.is_allowed_in(state_name):
			continue
		if behaviour != running and behaviour.is_cooling_down(tick):
			cooling |= bit
			continue
		if behaviour.needs_target and not has_target:
			continue
		if behaviour.presses_action != &"" and behaviour != running and not (abilities != null and context.inputs.action_ready(behaviour.presses_action)):
			can_press &= ~bit
			continue
		if not behaviour.has_own_code():
			continue # C++ checks its conditions against the inputs itself
		known |= bit
		if behaviour.is_available(context):
			available |= bit
			scores[slot] = behaviour.score(context)
	var row := _brain.size()
	_brain.append(brain)
	_pawn.append(context.pawn_number())
	_seed.append(context.random_seed)
	_tick.append(tick)
	_state.append(state_number)
	_has_target.append(1 if has_target else 0)
	_normal.append(1 if event_is_normal else 0)
	_priority.append(event_priority)
	_running.append(running.decision_index if running else -1)
	_started.append(running.started_tick if running else -1)
	_cooling.append(cooling)
	_can_press.append(can_press)
	_known.append(known)
	_available.append(available)
	_persistence_rows.append(persistence)
	_score_rows.append(scores)
	# A copy: GDScript note: the pawn's own array is written in place at its next decision, and a packed array put in an Array without
	# duplicate() can still share its storage.
	_input_rows.append(context.inputs.values.duplicate())
	_answers.append(-2)
	_names.append(manager.pawn.name)
	PerfScopes.end(&"ai.batch.gather", started)
	return row


## Notes GDScript's answer for a row: what runs after the decision (null: nothing).
func note_answer(row: int, chosen: AIBehaviourBase) -> void:
	if row >= 0 and row < _answers.size():
		_answers[row] = chosen.decision_index if chosen else -1


## Decides every row gathered so far in one C++ call, compares, and starts afresh. Runs at the end of each tick; a test calls it to
## settle decisions made by hand.
func decide_gathered() -> void:
	var rows := _brain.size()
	if rows == 0 or _decider == null:
		return
	var build_started := PerfScopes.begin()
	var stride: int = _decider.get_stride()
	var persistence := PackedFloat64Array()
	var scores := PackedFloat64Array()
	persistence.resize(rows * stride)
	scores.resize(rows * stride)
	scores.fill(NAN)
	for r in rows:
		var row_persistence := _persistence_rows[r]
		var row_scores := _score_rows[r]
		for slot in row_persistence.size():
			persistence[r * stride + slot] = row_persistence[slot]
			scores[r * stride + slot] = row_scores[slot]
	# The inputs, with one stride: the most slots any row has (a name first used during the tick makes later rows longer).
	var input_stride := 0
	for row_inputs in _input_rows:
		input_stride = maxi(input_stride, row_inputs.size())
	var inputs := PackedFloat64Array()
	inputs.resize(rows * input_stride)
	inputs.fill(0.0)
	for r in rows:
		var row_inputs := _input_rows[r]
		for i in row_inputs.size():
			inputs[r * input_stride + i] = row_inputs[i]
	var columns := {"brain": _brain, "pawn_number": _pawn, "random_seed": _seed, "tick": _tick, "state": _state,
		"has_target": _has_target, "event_normal": _normal, "event_priority": _priority, "running": _running,
		"running_started": _started, "cooling": _cooling, "can_press": _can_press, "available_known": _known,
		"available": _available, "persistence": persistence, "score": scores, "inputs": inputs, "input_stride": input_stride}
	PerfScopes.end(&"ai.batch.build", build_started)
	var decide_started := PerfScopes.begin()
	var answer: Dictionary = _decider.decide(columns)
	PerfScopes.end(&"ai.batch.decide", decide_started)
	var compare_started := PerfScopes.begin()
	_counts["batches"] += 1
	_counts["largest_batch"] = maxi(_counts["largest_batch"], rows)
	if not answer.is_empty():
		var chosen: PackedInt32Array = answer["chosen"]
		for r in rows:
			_counts["decisions"] += 1
			if _answers[r] == -2:
				_counts["unanswered"] += 1
			elif chosen[r] == _answers[r]:
				_counts["agreed"] += 1
			else:
				_counts["differs"] += 1
				if _counts["differs"] <= warnings_kept:
					push_warning("AIDecisionBatcher: the C++ decider disagreed at tick %d on %s: GDScript chose %s, C++ chose %s." % [
						_tick[r], _names[r], _slot_name(_brain[r], _answers[r]), _slot_name(_brain[r], chosen[r])])
	_clear_rows()
	PerfScopes.end(&"ai.batch.compare", compare_started)


# --- Internals ---


func _apply_mode() -> void:
	if mode == Mode.SHADOW and not ClassDB.class_exists(&"AIBatchDecider"):
		push_warning("AIDecisionBatcher: the navcore library has no AIBatchDecider, so shadow mode stays off.")
		mode = Mode.OFF
		return
	if mode == Mode.SHADOW:
		if _decider == null:
			_decider = ClassDB.instantiate(&"AIBatchDecider")
		AIBehaviourManager.decision_batcher = self
		if not _connected:
			TickDriver.after_tick.connect(_after_tick)
			_connected = true
	else:
		if AIBehaviourManager.decision_batcher == self:
			AIBehaviourManager.decision_batcher = null
		if _connected:
			TickDriver.after_tick.disconnect(_after_tick)
			_connected = false
		_clear_rows()


func _after_tick(_dt: float, _tick_number: int) -> void:
	decide_gathered()


# The decider's brain for this manager, added the first time it decides. Pawns with the same behaviour set share one.
func _brain_for(manager: AIBehaviourManager) -> int:
	var id := manager.get_instance_id()
	var known: Variant = _brain_of_manager.get(id)
	if known != null:
		return known
	var description := manager.describe()
	var shared := description.duplicate()
	for own: String in ["pawn", "pawn_number", "random_seed", "decision_interval_ticks"]:
		shared.erase(own)
	var text := JSON.stringify(shared, "", true, true)
	var brain: int = _brain_by_text.get(text, -2)
	if brain == -2:
		brain = _decider.add_brain(description) # -1, with an error, if it has too many behaviours
		_brain_by_text[text] = brain
		if brain >= 0:
			_state_numbers.append({})
	_brain_of_manager[id] = brain
	return brain


func _slot_name(brain: int, slot: int) -> String:
	return String(_decider.get_behaviour_name(brain, slot)) if slot >= 0 else "nothing"


# GDScript note: each column is cleared by name. Packed arrays are copied when put in another array, so clearing them through a list
# would clear the copies.
func _clear_rows() -> void:
	_brain.clear()
	_pawn.clear()
	_seed.clear()
	_tick.clear()
	_state.clear()
	_has_target.clear()
	_normal.clear()
	_priority.clear()
	_running.clear()
	_started.clear()
	_cooling.clear()
	_can_press.clear()
	_known.clear()
	_available.clear()
	_answers.clear()
	_persistence_rows.clear()
	_score_rows.clear()
	_input_rows.clear()
	_names.clear()
