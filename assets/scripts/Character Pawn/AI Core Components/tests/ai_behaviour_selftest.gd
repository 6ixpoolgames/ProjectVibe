## Written by Claude (claude-opus-5-5), 2026-11-03: headless self-test for AIBehaviourManagerComponent's selection rules.
## Each check matches a corner case documented at the top of AIBehaviourManagerComponent.gd. Exits 0 on success, 1 on failure.
## Run from the project folder (as a scene, so the project's autoloads exist):
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/Character Pawn/AI Core Components/tests/ai_behaviour_selftest.tscn"
extends Node

var _failures := 0


## A behaviour the test controls directly: fixed score, availability and tick result. Records what happened to it.
class Scripted extends AIBehaviourComponentBase:
	var fixedScore := 0.5
	var available := true
	var result := Status.RUNNING
	var enters := 0
	var lastExit := -1
	var tickDeltas: Array[float] = []

	func is_available(_c: AIContext) -> bool:
		return available

	func score(_c: AIContext) -> float:
		return fixedScore

	func enter(_c: AIContext) -> void:
		enters += 1

	func tick(_c: AIContext, delta: float) -> Status:
		tickDeltas.append(delta)
		return result

	func exit(_c: AIContext, reason: ExitReason) -> void:
		lastExit = reason


func _ready() -> void:
	print("--- AI behaviour self-test ---")
	var m := AIBehaviourManagerComponent.new()
	m.active = false # the test drives update() itself
	m.decision_interval = 0.25 # 0.25 and 1/32 are exact in binary, so frame sums hit the interval exactly
	add_child(m)
	var a := _add(m, "A", 0.3)
	var b := _add(m, "B", 0.6)
	var c := _add(m, "C", 0.0)

	# Claude 2026-11-04: defaults. NEVER_UNTIL_DONE is the base default; Idle overrides it because it never finishes.
	var plain := AIBehaviourComponentBase.new()
	_check(plain.interrupt_policy == AIBehaviourComponentBase.InterruptPolicy.NEVER_UNTIL_DONE, "default interrupt policy is NEVER_UNTIL_DONE")
	plain.free()
	var idle := IdleBehaviour.new()
	_check(idle.interrupt_policy == AIBehaviourComponentBase.InterruptPolicy.ALWAYS, "IdleBehaviour overrides it to ALWAYS")
	idle.free()

	# Highest score wins; score 0 is never picked.
	m.update(0.25)
	_check(m.current == b, "highest score wins (B)")
	_check(c.enters == 0, "score 0 is never picked")

	# Ticks happen once per decision interval, not every frame.
	b.tickDeltas.clear()
	for i in 8:
		m.update(0.03125) # 8 frames = 0.25 s
	_check(b.tickDeltas.size() == 1 and is_equal_approx(b.tickDeltas[0], 0.25), "running behaviour ticks once per interval with the elapsed delta")

	# Exact tie: the running one stays.
	a.fixedScore = 0.6
	m.update(0.25)
	_check(m.current == b, "exact tie keeps the running behaviour")

	# Default policy ALWAYS: switch as soon as something scores higher.
	a.fixedScore = 0.7
	m.update(0.25)
	_check(m.current == a and b.lastExit == AIBehaviourComponentBase.ExitReason.INTERRUPTED, "ALWAYS policy switches to a higher score (exit INTERRUPTED)")

	# NEVER_UNTIL_DONE: not interrupted by a better score...
	a.interrupt_policy = AIBehaviourComponentBase.InterruptPolicy.NEVER_UNTIL_DONE
	b.fixedScore = 0.9
	m.update(0.25)
	_check(m.current == a, "NEVER_UNTIL_DONE ignores a higher score")
	# ...but finishing hands over immediately, and the cooldown starts.
	a.cooldown = 1.0
	a.result = AIBehaviourComponentBase.Status.SUCCEEDED
	b.fixedScore = 0.1
	m.update(0.25)
	_check(a.lastExit == AIBehaviourComponentBase.ExitReason.SUCCEEDED and m.current == b, "on SUCCEEDED the next behaviour starts in the same update")
	a.result = AIBehaviourComponentBase.Status.RUNNING
	m.update(0.25)
	_check(m.current == b, "a finished behaviour is skipped while on cooldown")
	for i in 5:
		m.update(0.25)
	_check(m.current == a, "after its cooldown it can win again")

	# Eligibility beats policy: an unavailable behaviour is stopped even with NEVER_UNTIL_DONE.
	a.available = false
	m.update(0.25)
	_check(a.lastExit == AIBehaviourComponentBase.ExitReason.UNAVAILABLE and m.current == b, "unavailable behaviour is stopped despite NEVER_UNTIL_DONE")
	a.available = true
	a.interrupt_policy = AIBehaviourComponentBase.InterruptPolicy.ALWAYS

	# min_run_time: not interruptible before it, interruptible after.
	m.update(0.25) # a (0.7) beats b (0.1) again
	a.min_run_time = 0.5
	b.fixedScore = 0.9
	m.update(0.25)
	_check(m.current == a, "min_run_time blocks an early interrupt")
	m.update(0.4)
	_check(m.current == b, "after min_run_time it can be interrupted")
	a.min_run_time = 0.0

	# State gate: a behaviour for another state is stopped with STATE_CHANGED; "All" runs anywhere.
	b.stateName = &"Idle"
	a.stateName = &"All"
	m.context.currentState = &"Idle"
	m.update(0.25)
	_check(m.current == b, "state-matched behaviour runs")
	m.context.currentState = &"Aggressive"
	m.update(0.25)
	_check(b.lastExit == AIBehaviourComponentBase.ExitReason.STATE_CHANGED and m.current == a, "state change stops it (exit STATE_CHANGED); 'All' still eligible")
	m.context.currentState = &""
	_check(b.is_eligible_in_state(&""), "no known state: every behaviour is eligible")

	# No candidates: nothing runs.
	a.available = false
	b.available = false
	m.update(0.25)
	_check(m.current == null, "no candidates: nothing runs")

	# Wake on memory: a watched fact type being added decides on the very next update.
	var mem := AIMemoryComponent.new()
	add_child(mem)
	m.context.memory = mem
	b.available = true
	b.wake_on_facts = [&"pawn_seen"]
	m.update(0.25) # starts watching memory; b wins
	b.available = false
	a.available = true
	m.update(0.01) # mid-interval: no decision yet
	_check(m.current == b, "no decision between intervals")
	mem.record(&"pawn_seen", null, Vector3.ZERO)
	m.update(0.01)
	_check(m.current == a, "a watched memory fact triggers an immediate decision")

	# Removing the manager stops the running behaviour with REMOVED.
	remove_child(m)
	_check(a.lastExit == AIBehaviourComponentBase.ExitReason.REMOVED, "removing the manager exits the running behaviour (REMOVED)")
	m.free()

	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _add(m: AIBehaviourManagerComponent, id: String, s: float) -> Scripted:
	var b := Scripted.new()
	b.name = id
	b.fixedScore = s
	b.interrupt_policy = AIBehaviourComponentBase.InterruptPolicy.ALWAYS # the selection checks below start from ALWAYS and switch per case
	m.add_child(b)
	return b


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
