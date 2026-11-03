## Written by Claude (claude-opus-5-5), 2026-11-03: headless self-test for the nav core. Exits 0 on success, 1 on failure.
## Run from the project folder:
##   Godot_v4.4.1-stable_win64.exe --headless --path . --script res://assets/scripts/navigation/tests/nav_selftest.gd
##
## Test world: flat ground (y = 0) over 4x4 chunks (-64..64 m), with a 3 m wall along x at z = 0..1
## that has a ~2 m gap at x = 0. Small pawns (tier 0) path through the gap; big ones (tier 3) must
## walk around the wall's end at |x| = 40.
extends SceneTree

const N := 33 # samples per chunk edge (32 quads)
const SPACING := 1.0

var _failures := 0
var _layer := -1
var _gap_open := true


func _initialize() -> void:
	print("--- nav self-test ---")
	NavServer.configure({"worker_threads": 4})
	var hooks := NavHooks.new()
	_layer = NavServer.add_input_layer(null, hooks, NavServer.ADAPTER_HEIGHTMAP)
	for cz in range(-2, 2):
		for cx in range(-2, 2):
			_submit_chunk(Vector2i(cx, cz), AABB())
	NavServer.add_interest(Vector3.ZERO, 70.0, 90.0, 1)

	var t0 := Time.get_ticks_msec()
	_tick_until_idle()
	var s: Dictionary = NavServer.get_stats()
	print("initial build: %d ms wall clock, %d tiles ready, %d failed, avg %.2f ms/tile, max %.2f ms, max commit %.2f ms" % [
		Time.get_ticks_msec() - t0, s.ready, s.failed, s.avg_build_ms, s.max_build_ms, s.max_commit_ms])
	_check(s.ready > 0, "tiles were built")
	_check(s.failed == 0, "no tile failed")
	for t in NavServer.get_tile_states():
		if t.has("error"):
			print("  tile ", t.tile, " error: ", t.error)

	var a := Vector3(-10, 0, -10)
	var b := Vector3(10, 0, 10)

	# 1. Small pawn goes through the gap.
	var p0 := NavServer.find_path_now(a, b, 0)
	_check(p0.size() >= 2, "tier 0 path found")
	_check(_length(p0) < 40.0, "tier 0 path goes through the gap (length %.1f m)" % _length(p0))
	_check(_crosses_wall_near(p0, 0.0, 2.0), "tier 0 path crosses the wall at the gap")

	# 2. Big pawn has to go around the end of the wall.
	var p3 := NavServer.find_path_now(a, b, 3)
	_check(p3.size() >= 2, "tier 3 path found")
	_check(_length(p3) > 80.0, "tier 3 path goes around the wall (length %.1f m)" % _length(p3))

	# 3. Async (sliced) query gives the same answer as the sync one.
	var async_len := _async_path_length(a, b, 0)
	_check(absf(async_len - _length(p0)) < 0.5, "async path matches sync path (%.1f vs %.1f m)" % [async_len, _length(p0)])

	# 4. Edit: close the gap. Only the chunks around it are resubmitted, with tight dirty bounds.
	_gap_open = false
	var dirty := AABB(Vector3(-3, -10, -2), Vector3(6, 20, 5))
	for key in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]:
		_submit_chunk(key, dirty)
	t0 = Time.get_ticks_msec()
	_tick_until_idle()
	print("rebuild after edit: %d ms wall clock" % (Time.get_ticks_msec() - t0))
	var p0_closed := NavServer.find_path_now(a, b, 0)
	_check(_length(p0_closed) > 80.0, "with the gap closed, tier 0 goes around too (%.1f m)" % _length(p0_closed))

	# 5. Carve layer: a box mesh cuts a 3 m trench through the wall at x = 10..13.
	var carve_hooks := NavHooks.new()
	carve_hooks.layer_op = NavHooks.LAYER_OP_CARVE
	carve_hooks.order = 10
	var carve_layer := NavServer.add_input_layer(null, carve_hooks, NavServer.ADAPTER_MESH)
	NavServer.submit_mesh(carve_layer, 1, _box_faces(Vector3(10, -0.3, -1.5), Vector3(13, 6, 2.5)), Transform3D.IDENTITY)
	_tick_until_idle()
	var p_trench := NavServer.find_path_now(a, b, 0)
	_check(_length(p_trench) < 60.0, "path uses the carved trench (%.1f m)" % _length(p_trench))
	_check(_crosses_wall_near(p_trench, 11.5, 2.5), "path crosses the wall at the trench")

	# 6. Remove the carve layer: back to going around.
	NavServer.remove_input_layer(carve_layer)
	_tick_until_idle()
	_check(_length(NavServer.find_path_now(a, b, 0)) > 80.0, "removing the carve layer restores the wall")

	# 7. Unloading: move the interest far away, tiles should go.
	NavServer.add_interest(Vector3(5000, 0, 5000), 10.0, 10.0, 0)
	NavServer.remove_interest(1)
	_tick_until_idle()
	_check(NavServer.get_stats().live_detour_tiles == 0, "tiles unload when no interest wants them")

	s = NavServer.get_stats()
	print("totals: %d builds committed, %d stale builds discarded, max tick %.2f ms" % [s.builds_committed, s.builds_stale, s.max_tick_ms])
	if _failures == 0:
		print("--- ALL PASSED ---")
	else:
		print("--- %d FAILED ---" % _failures)
	quit(0 if _failures == 0 else 1)


func _height(wx: float, wz: float) -> float:
	var in_wall := wz >= 0.0 and wz <= 1.0 and absf(wx) <= 40.0
	if in_wall and (absf(wx) >= 2.0 or not _gap_open):
		return 3.0
	return 0.0


func _submit_chunk(key: Vector2i, dirty: AABB) -> void:
	var h := PackedFloat32Array()
	h.resize(N * N)
	for z in N:
		for x in N:
			h[x + z * N] = _height(key.x * (N - 1) * SPACING + x * SPACING, key.y * (N - 1) * SPACING + z * SPACING)
	NavServer.submit_heightmap(_layer, key, h, Vector2i(N, N), SPACING, PackedByteArray(), dirty)


func _tick_until_idle() -> void:
	for i in 2000:
		NavServer.tick(1.0 / 60.0)
		if i > 2 and NavServer.is_idle():
			return
		OS.delay_msec(2)
	_check(false, "nav became idle within the time limit")


func _async_path_length(from: Vector3, to: Vector3, tier: int) -> float:
	var result := {"done": false, "len": -1.0}
	var id := NavServer.find_path(from, to, tier)
	var on_ready := func(rid: int, points: PackedVector3Array, _partial: bool):
		if rid == id:
			result.done = true
			result.len = _length(points)
	var on_fail := func(rid: int, reason: String):
		if rid == id:
			result.done = true
			print("  async failed: ", reason)
	NavServer.path_ready.connect(on_ready)
	NavServer.path_failed.connect(on_fail)
	for i in 600:
		NavServer.tick(1.0 / 60.0)
		if result.done:
			break
	NavServer.path_ready.disconnect(on_ready)
	NavServer.path_failed.disconnect(on_fail)
	return result.len


func _length(points: PackedVector3Array) -> float:
	if points.size() < 2:
		return 0.0
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total


# Does the path cross the wall line (z = 0.5) within `half_width` of x = `at_x`?
func _crosses_wall_near(points: PackedVector3Array, at_x: float, half_width: float) -> bool:
	for i in range(1, points.size()):
		var p := points[i - 1]
		var q := points[i]
		if (p.z - 0.5) * (q.z - 0.5) <= 0.0 and absf(q.z - p.z) > 0.0001:
			var t := (0.5 - p.z) / (q.z - p.z)
			var x := lerpf(p.x, q.x, t)
			if absf(x - at_x) <= half_width:
				return true
	return false


func _box_faces(lo: Vector3, hi: Vector3) -> PackedVector3Array:
	var c := [
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
	]
	var quads := [[0, 1, 2, 3], [7, 6, 5, 4], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]]
	var faces := PackedVector3Array()
	for q in quads:
		faces.append_array([c[q[0]], c[q[1]], c[q[2]], c[q[0]], c[q[2]], c[q[3]]])
	return faces


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
