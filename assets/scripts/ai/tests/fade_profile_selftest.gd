## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for FadeProfile. Checks each mode's shape, the hold, when each
## ends, the odd cases at the top of FadeProfile.gd, and that a script extending it is picked up.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/ai/tests/fade_profile_selftest.tscn"
extends Node

var _failures := 0


## A fade no mode covers: steps straight from full to nothing at tick 10.
class StepFade extends FadeProfile:
	func value_at(ticks: float) -> float:
		return 1.0 if ticks < 10.0 else 0.0

	func ends_after() -> int:
		return 10


func _ready() -> void:
	print("--- FadeProfile self-test ---")
	_test_linear()
	_test_half_life()
	_test_curve()
	_test_odd_cases()
	_test_extended()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_linear() -> void:
	var fade := FadeProfile.new()
	fade.mode = FadeProfile.Mode.LINEAR
	fade.hold_ticks = 20
	fade.fade_ticks = 40
	_check(is_equal_approx(fade.value_at(0), 1.0) and is_equal_approx(fade.value_at(19), 1.0), "linear: full during the hold")
	_check(is_equal_approx(fade.value_at(40), 0.5), "linear: half way through the fade, half (%.3f)" % fade.value_at(40))
	_check(fade.ends_after() == 60 and fade.value_at(60) == 0.0 and fade.value_at(500) == 0.0, "linear: nothing from hold + fade (60) on")
	_check(fade.value_at(59) > 0.0, "linear: still something just before the end")


func _test_half_life() -> void:
	var fade := FadeProfile.new()
	fade.mode = FadeProfile.Mode.HALF_LIFE
	fade.hold_ticks = 10
	fade.half_life_ticks = 30
	_check(is_equal_approx(fade.value_at(10), 1.0), "half-life: full at the end of the hold")
	_check(is_equal_approx(fade.value_at(40), 0.5) and is_equal_approx(fade.value_at(70), 0.25), "half-life: halves every 30 ticks after the hold")
	_check(fade.value_at(25) < 1.0 and fade.value_at(25) > 0.5, "half-life: smooth between halvings (%.3f)" % fade.value_at(25))
	_check(fade.ends_after() == 10 + 30 * 7, "half-life: ends after 7 halvings (%d ticks)" % fade.ends_after())
	_check(fade.value_at(fade.ends_after() - 1) > 0.0 and fade.value_at(fade.ends_after() - 1) < 0.01, "half-life: under 1% just before the end")
	_check(fade.value_at(fade.ends_after()) == 0.0, "half-life: exactly nothing at the end")


func _test_curve() -> void:
	var fade := FadeProfile.new()
	fade.mode = FadeProfile.Mode.CURVE
	fade.hold_ticks = 0
	fade.fade_ticks = 100
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(0.5, 0.9)) # a slow start
	curve.add_point(Vector2(1.0, 0.0)) # and a quick end
	fade.curve = curve
	_check(fade.value_at(50) > 0.8, "curve: follows the drawn shape (%.3f at the middle)" % fade.value_at(50))
	_check(fade.ends_after() == 100 and fade.value_at(100) == 0.0, "curve: nothing after fade_ticks")
	var wild := Curve.new()
	wild.min_value = -1.0
	wild.max_value = 2.0
	wild.add_point(Vector2(0.0, 2.0))
	wild.add_point(Vector2(1.0, -1.0))
	fade.curve = wild
	_check(fade.value_at(1) <= 1.0 and fade.value_at(99) >= 0.0, "curve: a curve outside 0 to 1 is kept between them")


func _test_odd_cases() -> void:
	var fade := FadeProfile.new()
	_check(fade.mode == FadeProfile.Mode.LINEAR and fade.value_at(-5) == 1.0, "before the start: full")
	fade.hold_ticks = 5
	fade.fade_ticks = 0
	_check(fade.value_at(4) == 1.0 and fade.value_at(5) == 0.0, "linear with no fade: full for the hold, then nothing at once")
	fade.mode = FadeProfile.Mode.HALF_LIFE
	fade.half_life_ticks = 0
	_check(fade.value_at(4) == 1.0 and fade.value_at(5) == 0.0, "half-life of 0: the same")
	var no_curve := FadeProfile.new()
	no_curve.mode = FadeProfile.Mode.CURVE
	no_curve.fade_ticks = 10
	print("  (a warning about a missing curve is expected next)")
	_check(is_equal_approx(no_curve.value_at(5), 0.5), "curve with nothing drawn: a straight line instead")


func _test_extended() -> void:
	var fade: FadeProfile = StepFade.new()
	_check(fade.value_at(9) == 1.0 and fade.value_at(10) == 0.0 and fade.ends_after() == 10, "a script extending it replaces both functions")


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
