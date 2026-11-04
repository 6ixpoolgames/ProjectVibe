## Written by Claude (claude-opus-5-5), 2026-11-03: headless self-test for AIMemoryComponent. Exits 0 on success, 1 on failure.
## Run from the project folder (as a scene, so the project's autoloads exist):
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/Character Pawn/AI Core Components/tests/ai_memory_selftest.tscn"
## Drives fading with decay_by() instead of waiting real time, so it runs instantly.
extends Node

var _failures := 0
var _forgotten: Array = []


func _ready() -> void:
	print("--- AI memory self-test ---")
	var mem := AIMemoryComponent.new()
	mem.default_half_life = 2.0
	mem.forget_below = 0.1
	mem.fact_forgotten.connect(func(f): _forgotten.append(f))
	add_child(mem) # no AI core parent: it should just work standalone

	var enemy := Node3D.new()
	var friend := Node3D.new()

	# 1. Record and refresh: same (type, subject) is one fact, position updates.
	mem.record(&"pawn_seen", enemy, Vector3(1, 0, 0), 1.0, &"vision")
	mem.record(&"pawn_seen", enemy, Vector3(5, 0, 0), 1.0, &"vision")
	_check(mem.get_facts(&"pawn_seen").size() == 1, "refreshing the same subject keeps one fact")
	_check(mem.get_fact_about(enemy).position == Vector3(5, 0, 0), "refresh moves the last known position")

	# 2. Fading: one half-life halves confidence; a weak report doesn't lower it.
	mem.decay_by(2.0)
	_check(is_equal_approx(mem.get_fact_about(enemy).confidence, 0.5), "confidence halves after one half-life (%.3f)" % mem.get_fact_about(enemy).confidence)
	mem.record(&"pawn_seen", enemy, Vector3(5, 0, 0), 0.2)
	_check(is_equal_approx(mem.get_fact_about(enemy).confidence, 0.5), "a weaker report doesn't lower confidence")

	# 3. Forgetting: below the threshold the fact goes, and the signal fires.
	mem.decay_by(6.0) # 0.5 -> 0.0625, under 0.1
	_check(mem.get_fact_about(enemy) == null, "fact forgotten once confidence drops below forget_below")
	_check(_forgotten.size() == 1, "fact_forgotten signal fired")

	# 4. Per-type half-life override (inspector-style String key).
	mem.half_life_by_type = {"pawn_seen": 100.0}
	mem.record(&"pawn_seen", friend, Vector3.ZERO)
	mem.record(&"heard_noise", null, Vector3(20, 0, 0))
	mem.decay_by(2.0)
	_check(mem.get_fact_about(friend).confidence > 0.95, "per-type half-life slows pawn_seen fading")
	_check(is_equal_approx(mem.get_most_recent(&"heard_noise").confidence, 0.5), "other types keep the default half-life")

	# 5. Subject-less facts merge by distance.
	mem.record(&"heard_noise", null, Vector3(21, 0, 0))
	mem.record(&"heard_noise", null, Vector3(40, 0, 0))
	_check(mem.get_facts(&"heard_noise").size() == 2, "noises within merge radius merge, far ones don't")

	# 6. Freed subjects are forgotten on the next pass.
	friend.free()
	mem.decay_by(0.01)
	_check(mem.get_facts(&"pawn_seen").is_empty(), "facts about freed nodes are forgotten")

	# 7. Capacity: when full, the least confident fact makes room.
	mem.clear()
	mem.max_facts = 3
	mem.record(&"a", null, Vector3(0, 0, 0), 0.9)
	mem.record(&"a", null, Vector3(10, 0, 0), 0.3)
	mem.record(&"a", null, Vector3(20, 0, 0), 0.8)
	mem.record(&"a", null, Vector3(30, 0, 0), 1.0)
	_check(mem.facts.size() == 3 and mem.get_least_confident().confidence >= 0.8, "full memory drops the least confident fact")

	# 8. Queries.
	_check(mem.has_fact(&"a", 0.95) and not mem.has_fact(&"a", 1.01), "has_fact respects min_confidence")
	_check(mem.get_most_confident(&"a").position == Vector3(30, 0, 0), "get_most_confident picks the strongest")

	enemy.free()
	mem.free()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
