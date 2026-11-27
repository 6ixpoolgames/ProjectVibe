## Written by Claude (claude-opus-5-5), 2026-11-17: headless self-test for AIDecisionRecord, AIDecisionRecorder and the AI's finer
## timing scopes (scaling spec 6.2, step 5a: the first piece of the shadow decider). Checks that nothing is recorded with no listener,
## that a record holds the hard rule, range, availability and score of every behaviour and the choice, the three causes (the AI step
## with its target and state updates, a behaviour ending, a direct call), the interrupt rule keeping a behaviour, jitter values that
## a second decider can work out again, the early stop's "never asked", saving to a file, and the timing scope names.
## Claude 2026-11-27 (AI scoring proposal): ceilings and floors are gone; an entry has its result known up front (key, null for a
## score() of its own) and the multiply and add its score got.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/ai/tests/ai_decision_recorder_selftest.tscn"
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NEVER := 100000000 # a decision interval so long the pawn never decides on its own, so the test decides by hand
const SAVE_PATH := "user://ai_decision_recorder_selftest.jsonl"


## A behaviour a test controls: its score, whether it's available, and how its tick ends.
class TestBehaviour extends AIBehaviourBase:
	var value := 0.5
	var available := true
	var finish_with := Status.RUNNING

	func is_available(_context: AIManager) -> bool:
		return available

	func score(_context: AIManager) -> float:
		return value

	func tick(_context: AIManager) -> Status:
		return finish_with


## A state a test can switch on.
class SwitchState extends AIStateBase:
	var fits := false

	func prerequisites_met(_context: AIManager) -> bool:
		return fits


var _recorder: AIDecisionRecorder = null


func _ready() -> void:
	TagRegistry.declare([&"ai.state.alarm"]) # the test's own Alarm state's tag (AIStateBase.get_tag)
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # the checks count exact ticks at 60 a second
	print("--- AI decision recorder self-test ---")
	# Claude 2026-11-26 (pawn spec 16.10 step 6d): GDScript's decider, whose records hold every behaviour's numbers. Its test behaviours
	# have code of their own, which no longer keeps a pawn out of C++, and a C++ decision's record leaves those numbers out.
	AIDecisionChecks.set_all_in_gdscript(true)
	_recorder = AIDecisionRecorder.new()
	add_child(_recorder)
	_test_nothing_without_listener()
	_test_record_of_a_decision()
	_test_behaviour_ended()
	_test_kept_by_interrupt()
	_test_jitter_and_early_stop()
	_test_ai_step()
	_test_save()
	_test_timings()
	await _test_stop()
	AIDecisionChecks.set_all_in_gdscript(false)
	_finish()


func _test_nothing_without_listener() -> void:
	_check(not AIBehaviourManager.decision_listener.is_valid(), "no listener by default")
	var pawn := _make_pawn([_b("Alpha", 0.5)])
	_decide(pawn, 1)
	_check_equal(_recorder.get_records().size(), 0, "with no listener, nothing is recorded")
	pawn.free()


func _test_record_of_a_decision() -> void:
	var low := _b("Alpha", 0.3)
	var best := _b("Bravo", 0.7)
	var hunter := _b("Hunt", 1.0)
	hunter.needs_target = true
	var elsewhere := _b("Elsewhere", 1.0)
	elsewhere.tag_requirements = TagQuery.make([Tags.AI.STATE_COMBAT])
	var presser := _b("Press", 1.0)
	presser.presses_action = &"no_such_action"
	var pawn := _make_pawn([low, best, hunter, elsewhere, presser])
	_recorder.start()
	_check(_recorder.is_recording() and AIBehaviourManager.decision_listener.is_valid(), "start() sets the listener")
	_decide(pawn, 10)
	var records := _recorder.get_records()
	_check_equal(records.size(), 1, "one decision, one record")
	if records.is_empty():
		return
	var record := records[0]
	_check_equal(record.tick, 10, "the record has the tick")
	_check_equal(record.cause, AIDecisionRecord.CAUSE_DIRECT, "a direct call to decide() says so")
	_check_equal(record.chosen, &"Bravo", "...and what it chose")
	_check(record.changed() and record.running_before == &"", "...and that it changed from nothing")
	_check_equal(record.state, &"Idle", "...and the state it judged in")
	_check_equal(record.behaviours.size(), 5, "one entry per behaviour")
	var names: Array = []
	for entry in record.behaviours:
		names.append(entry["name"])
	_check_equal(names, [&"Alpha", &"Bravo", &"Elsewhere", &"Hunt", &"Press"], "...in the fixed order, by name")
	_check_equal(record.entry_for(&"Elsewhere")["rule"], AIDecisionRecord.RULE_TAGS, "a behaviour for another state: its rule (its tag requirements)")
	_check_equal(record.entry_for(&"Hunt")["rule"], AIDecisionRecord.RULE_NO_TARGET, "one needing a target: its rule")
	_check_equal(record.entry_for(&"Press")["rule"], AIDecisionRecord.RULE_ACTION, "one whose action can't start: its rule")
	var bravo := record.entry_for(&"Bravo")
	_check(bravo["rule"] == AIDecisionRecord.RULE_NONE and bravo["available"] == 1, "the winner: a candidate, asked, available")
	_check_near(bravo["score"], 0.7, 0.000001, "...with its score")
	_check(bravo["key"] == null and bravo["score_multiply"] == 1.0 and bravo["score_add"] == 0.0,
			"...no result known up front (its score() is its own), and no modifiers on its score")
	var brain := _recorder.get_brain(record.pawn_number)
	_check_equal(brain.get("behaviours", []).size(), 5, "the pawn's brain is described once, with every behaviour")
	_check_equal(brain["behaviours"][1]["name"], "Bravo", "...in the same order")
	_check_equal(brain["behaviours"][1]["name_hash"], best.name_hash, "...with the hash its random numbers use")
	_check_equal(_recorder.summary()["decisions"], 1, "summary() counts it")
	_decide(pawn, 11)
	_check(not _recorder.get_records()[1].changed(), "the same choice again: not a change")
	pawn.free()
	_recorder.clear()


func _test_behaviour_ended() -> void:
	var quick := _b("Quick", 0.9)
	quick.cooldown_ticks = 10
	quick.finish_with = AIBehaviourBase.Status.SUCCEEDED
	var pawn := _make_pawn([quick, _b("Fallback", 0.1)])
	_decide(pawn, 100)
	pawn.ai.behaviour_manager.tick_running(101) # Quick finishes; the manager decides at once
	var records := _recorder.get_records()
	_check_equal(records.size(), 2, "a behaviour ending decides again, and that's recorded")
	if records.size() < 2:
		return
	var record := records[1]
	_check_equal(record.cause, AIDecisionRecord.CAUSE_BEHAVIOUR_ENDED, "...as a behaviour ending")
	_check_equal(record.running_before, &"", "...with nothing running (the finished one has stopped)")
	_check_equal(record.entry_for(&"Quick")["rule"], AIDecisionRecord.RULE_COOLDOWN, "...and the finished one cooling down")
	_check_equal(record.chosen, &"Fallback", "...so the fallback runs")
	_check_equal(record.state_before, record.state, "no state update ran: before is the state it judged in")
	pawn.free()
	_recorder.clear()


func _test_kept_by_interrupt() -> void:
	var stubborn := _b("Stubborn", 0.5)
	stubborn.cannot_be_interrupted = true
	var stronger := _b("Stronger", 0.9)
	stronger.available = false
	var pawn := _make_pawn([stubborn, stronger])
	_decide(pawn, 1)
	stronger.available = true
	_decide(pawn, 2)
	var record := _recorder.get_records()[1]
	# Claude 2026-11-25 (pawn spec 16.10 step 6a): a kept record holds the running behaviour's numbers, which its modifiers may change.
	_check(record.kept_by_interrupt and record.behaviours.size() == 1 and record.behaviours[0]["rule"] == AIDecisionRecord.RULE_KEPT,
			"a behaviour that can't be interrupted: kept, nothing looked at but its own numbers")
	_check(record.chosen == &"Stubborn" and record.running_before == &"Stubborn", "...and it's still the choice")
	_check_equal(record.running_started_tick, 1, "...with the tick it started")
	pawn.free()
	_recorder.clear()


func _test_jitter_and_early_stop() -> void:
	var high := _plain("High", 0.9) # scores from settings, so the walk knows each result up front
	var low := _plain("Low", 0.4)
	low.score_jitter = 0.1
	var pawn := _make_pawn([high, low])
	_decide(pawn, 500)
	var record := _recorder.get_records()[0]
	var low_entry := record.entry_for(&"Low")
	_check_equal(low_entry["available"], -1, "the early stop: Low (at most 0.5) is never asked once High is available at 0.9")
	_check(low_entry["score"] == null, "...and never scored")
	var expected := 0.1 * pawn.ai.random_signed(low.name_hash) # the context's tick is still 500
	_check_near(low_entry["jitter"], expected, 0.0000001, "its jitter can be worked out again from the tick, pawn and name hash")
	_check_near(low_entry["key"], 0.4 + expected, 0.0000001, "...and its result is its score plus that jitter")
	pawn.free()
	_recorder.clear()


func _test_ai_step() -> void:
	var alarm := SwitchState.new()
	alarm.name = "Alarm"
	alarm.priority = 10
	var wander := _b("Wander", 0.5)
	var react := _b("React", 0.8)
	react.tag_requirements = TagQuery.make([&"ai.state.alarm"])
	var pawn := _make_pawn([wander, react], [alarm])
	pawn.ai.decision_interval_ticks = 1 # decides on every AI step
	pawn.ai.run_ai(200)
	alarm.fits = true
	pawn.ai.run_ai(201)
	var records := _recorder.get_records()
	_check(records.size() >= 2, "the AI step's decisions are recorded (%d)" % records.size())
	if records.size() < 2:
		return
	var first := records[0]
	var second := records[records.size() - 1]
	_check_equal(first.cause, AIDecisionRecord.CAUSE_AI_STEP, "as the AI step")
	_check_equal(first.chosen, &"Wander", "first in Idle: Wander")
	_check(second.state_before == &"Idle" and second.state_after == &"Alarm", "the state update is in the record: Idle to Alarm")
	_check(not second.event_is_normal and second.event_priority == 10, "...and so is the state change's reason, priority 10")
	_check_equal(second.chosen, &"React", "...and the choice in Alarm: React")
	_check(second.target_before_id == 0 and second.target_after_id == 0, "no target before or after")
	pawn.free()


func _test_save() -> void:
	var count := _recorder.get_records().size()
	_check_equal(_recorder.save(SAVE_PATH), OK, "save() writes the file")
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	var brains := 0
	var decisions := 0
	var all_parse := true
	while file and not file.eof_reached():
		var line := file.get_line()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if not parsed is Dictionary:
			all_parse = false
			continue
		brains += 1 if parsed["kind"] == "brain" else 0
		decisions += 1 if parsed["kind"] == "decision" else 0
	if file:
		file.close()
	_check(all_parse, "every line is a JSON object")
	_check(brains == 1 and decisions == count, "one brain line and one line per decision (%d brains, %d of %d decisions)" % [brains, decisions, count])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	_recorder.clear()


func _test_timings() -> void:
	var was_enabled := PerfScopes.enabled
	var was_detailed := PerfScopes.detailed
	PerfScopes.enabled = true
	var alarm := SwitchState.new()
	alarm.name = "Alarm"
	var quick := _b("Quick", 0.9)
	quick.finish_with = AIBehaviourBase.Status.SUCCEEDED
	var pawn := _make_pawn([quick, _plain("Slow", 0.5)], [alarm]) # Claude 2026-11-27: a score from settings, so the walk can skip it
	pawn.ai.decision_interval_ticks = 1
	# Claude 2026-11-17: without detail, only the coarse scopes; the fine ones (one per state, behaviour and sense) cost too much to
	# run always.
	PerfScopes.detailed = false
	PerfScopes.take_frame() # start afresh; everything below runs before any other code can take a frame
	pawn.ai.run_ai(299)
	pawn.ai.sensing_manager.full_pass(299)
	var coarse := PerfScopes.take_frame()
	_check(coarse.has(&"ai.decide.behaviour") and not coarse.has(&"ai.state.Idle") and not coarse.has(&"ai.behaviour.Quick")
			and not coarse.has(&"ai.sense.Sight.full"), "detail off: the coarse scopes only, none per state, behaviour or sense")
	PerfScopes.detailed = true
	PerfScopes.take_frame()
	pawn.ai.run_ai(300)
	pawn.ai.sensing_manager.full_pass(300)
	var scopes := PerfScopes.take_frame()
	PerfScopes.enabled = was_enabled
	PerfScopes.detailed = was_detailed
	for scope: StringName in [&"ai.decide", &"ai.decide.target", &"ai.decide.state", &"ai.decide.behaviour", &"ai.decide.switch",
			&"ai.state.Alarm", &"ai.state.Idle", &"ai.available.Quick", &"ai.behaviour.Quick", &"ai.sense.Sight.full",
			&"ai.memory.forget"]:
		_check(scopes.has(scope), "timed: %s" % scope)
	_check(not scopes.has(&"ai.available.Slow"), "the early stop shows: Slow was never asked, so never timed")
	pawn.free()
	_recorder.clear()


func _test_stop() -> void:
	_recorder.stop()
	_check(not _recorder.is_recording() and not AIBehaviourManager.decision_listener.is_valid(), "stop() clears the listener")
	var other := AIDecisionRecorder.new()
	add_child(other)
	other.start()
	_recorder.stop() # an old recorder stopping again must not silence the new one
	_check(AIBehaviourManager.decision_listener.is_valid(), "stopping an old recorder leaves a newer one listening")
	other.queue_free()
	await get_tree().process_frame
	_check(not AIBehaviourManager.decision_listener.is_valid(), "a recorder leaving the tree stops listening")


# --- Helpers ---


func _b(behaviour_name: String, value: float) -> TestBehaviour:
	var behaviour := TestBehaviour.new()
	behaviour.name = behaviour_name
	behaviour.value = value
	return behaviour


## A behaviour scored from its settings, always available.
func _plain(behaviour_name: String, score: float) -> AIBehaviourBase:
	var behaviour := AIBehaviourBase.new()
	behaviour.name = behaviour_name
	behaviour.base_score = score
	return behaviour


## A pawn whose behaviour manager holds these behaviours, and whose state manager holds these states plus Idle. It never decides
## on its own unless the test changes decision_interval_ticks.
func _make_pawn(behaviours: Array, states: Array = [], at := Vector3(0, 1000, 0)) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	var manager := AIBehaviourManager.new()
	manager.name = "AIBehaviourManager"
	for behaviour in behaviours:
		manager.add_child(behaviour)
	AITestPawns.ai_of(pawn).add_child(manager)
	if not states.is_empty():
		var state_manager := AIStateManager.new()
		state_manager.name = "AIStateManager"
		for state in states:
			state_manager.add_child(state)
		var idle := AIIdleState.new()
		idle.name = "Idle"
		state_manager.add_child(idle)
		AITestPawns.ai_of(pawn).add_child(state_manager)
	add_child(pawn)
	pawn.ai.decision_interval_ticks = NEVER
	return pawn


## Makes one decision now, as the pawn's AI step would: the state is checked, then the behaviour manager decides.
func _decide(pawn: Pawn, tick: int) -> void:
	var context := pawn.ai
	context.current_tick = tick
	context.request_decision()
	context.state_manager.update_state(tick)
	context.behaviour_manager.decide(tick)
