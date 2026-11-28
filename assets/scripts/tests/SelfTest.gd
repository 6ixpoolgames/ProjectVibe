## Written by Claude (claude-fable-5-2), 2026-11-16 (the wider code audit): what every headless test shares. A test scene's script
## extends this instead of Node:
##
##   extends SelfTest
##
##   func _ready() -> void:
##       _check(2 + 2 == 4, "sums work")                              # prints "  ok   sums work", or "  FAIL sums work"
##       _check_equal(pawn.team, 1, "the goblin is on team 1")        # a failure also says what it got and what was wanted
##       _check_near(pawn.velocity.x, 5.0, 0.05, "it walks at 5 m/s") # for numbers that are never exact
##       _finish()                                                    # prints the last line and quits with 0 or 1
##
## Before this, the same _check function was written out in 49 test files, and a failed check only said which rule broke, not what
## the value was. tools/run_tests.sh runs the tests and reads these lines.
##
## It also pins what a loaded machine would change under a test: TickDriver's load step stays at 1, so AI pawns run every tick however
## busy the computer is. A test of the load ladder sets it back (tick_step_selftest does).
##
## This is test code: it lives in a tests/ folder and nothing that ships uses it (docs/TEST_AND_DEBUG_CODE.md).
class_name SelfTest
extends Node

## How many checks have failed so far.
var _failures := 0


# GDScript note: _enter_tree runs before _ready, so this is in place before the test's own code starts.
func _enter_tree() -> void:
	TickDriver.load_step_override = 1


## One check. what says the rule being checked, in plain words.
func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1


## A check that two values are equal. When they aren't, the line says both.
func _check_equal(got: Variant, wanted: Variant, what: String) -> void:
	# GDScript note: values of different types are never equal here, so 1 and 1.0 fail, which is usually a real mistake.
	var same: bool = typeof(got) == typeof(wanted) and got == wanted
	_check(same, what if same else "%s (got %s, wanted %s)" % [what, str(got), str(wanted)])


## A check that a number is within tolerance of the one wanted. When it isn't, the line says both.
func _check_near(got: float, wanted: float, tolerance: float, what: String) -> void:
	var near := absf(got - wanted) <= tolerance
	_check(near, what if near else "%s (got %s, wanted %s within %s)" % [what, str(got), str(wanted), str(tolerance)])


## Prints the last line every test ends with, and quits: exit code 0 if every check passed, 1 if any failed.
## Sets a pawn's Detectability stat's base value (what effects build on), as stealth tests need. Nothing for a pawn without the stat.
static func set_detectability(of_pawn: Node, value: float) -> void:
	var manager: StatusManager = of_pawn.get(&"status_manager") if of_pawn else null
	var stat: Stat = manager.get_stat(StatusManager.DETECTABILITY) if manager else null
	if stat:
		stat.base_value = value


func _finish() -> void:
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)
