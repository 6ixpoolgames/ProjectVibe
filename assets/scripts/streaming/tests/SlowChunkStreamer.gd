## Written by Claude (claude-opus-5-5), 2026-11-07: a ChunkStreamer that acts like a slower CPU, for stress tests and the streaming
## sample. It's test code, kept out of ChunkStreamer so that none of this goes into a real game.
##
## It wraps each piece of the streamer's work and waits afterwards, so that the piece took simulate_slower_cpu times as long. It
## really does use the time, so the streamer's budget check and the frame rate behave as they would on a slower machine. It doesn't
## slow nav's background threads, physics or drawing, so it's a rough guide and not a real slow machine.
class_name SlowChunkStreamer
extends ChunkStreamer

## Makes every step take this many times as long. 1 is off.
@export_range(1.0, 10.0, 0.1) var simulate_slower_cpu := 1.0


## Forgets the worst times so far, so a test can measure one part of a run on its own.
func reset_worst_times() -> void:
	_worst_frame_usec = 0
	_worst_step_usec = 0


# GDScript note: a function here with the same name as one in ChunkStreamer replaces it, and super() runs the original.
func _refresh() -> void:
	var started := Time.get_ticks_usec()
	super()
	_slow_down(started)


func _build_now(key: Vector2i) -> void:
	var started := Time.get_ticks_usec()
	super(key)
	_slow_down(started)


func _build_next_step() -> void:
	var started := Time.get_ticks_usec()
	super()
	_slow_down(started)


func _unload_next() -> void:
	var started := Time.get_ticks_usec()
	super()
	_slow_down(started)


func _slow_down(started: int) -> void:
	if simulate_slower_cpu <= 1.0:
		return
	var took := Time.get_ticks_usec() - started
	var until := started + int(took * simulate_slower_cpu)
	while Time.get_ticks_usec() < until:
		pass
