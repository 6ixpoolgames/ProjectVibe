## Written by Claude (claude-opus-5-5), 2026-11-05: a test pawn with state that lives in save_state and load_state, not in the
## property lists, for checking that kind of state reaches clients and gets corrected. Used with net_test_node's --custom.
##
## bonus is changed by the server on a tick no client can predict. total adds bonus every simulated tick, so if a client's replay
## starts from the wrong bonus, or doesn't replay at all, total comes out wrong.
extends NetTestPawn
class_name NetTestCustomPawn

var bonus := 0
var total := 0


func save_state() -> Dictionary:
	return {"bonus": bonus, "total": total}


func load_state(saved: Dictionary) -> void:
	bonus = saved["bonus"]
	total = saved["total"]


func _tick_simulate(dt: float, tick: int) -> void:
	super(dt, tick)
	total += bonus
