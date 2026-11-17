## Written by Claude (claude-opus-5-5), 2026-11-16: what each physics query the CrowdMover uses costs, and what move_and_slide costs, for
## a pawn alone and for one in the middle of a packed crowd, the owner's request ("test its cost in a worst case surrounded by other
## pawns, just so we have the profile"). Not pass/fail: it prints microseconds per call. Pawn spec 8.22.
##   godot --headless --path . "res://assets/scripts/movement/tests/crowd_query_measure.tscn"
## The crowd: 12 pawns touching the middle one, and 24 more just outside them. "On a slope" puts all of it on a 25 degree ramp, where
## the lifted sweep passes close over the ground. The last rows time the CrowdMover's whole batch for every pawn walking inward.
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const CALLS := 3000

var _pawns: Array[Pawn] = []


func _ready() -> void:
	print("--- Crowd mover query costs (microseconds a call) ---")
	var floor_body := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400), 0.0)
	await _settle_then_measure("alone, flat ground", Vector3.ZERO, false)
	await _settle_then_measure("in a crowd of 36, flat ground", Vector3.ZERO, true)
	floor_body.free()
	var ramp := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400), deg_to_rad(25.0))
	await _settle_then_measure("in a crowd of 36, on a 25 degree slope", Vector3.ZERO, true)
	ramp.free()
	print("--- done ---")
	get_tree().quit(0)


func _settle_then_measure(label: String, centre: Vector3, crowd: bool) -> void:
	var middle := _make_pawn(centre + Vector3(0, 0.3, 0))
	if crowd:
		for ring: Array in [[12, 0.85], [24, 1.7]]:
			for i in ring[0]:
				var angle: float = TAU * i / float(ring[0])
				_make_pawn(centre + Vector3(cos(angle) * ring[1], 0.3, sin(angle) * ring[1]))
	# A few ticks to land, then the game stops ticking so nothing moves while it's timed.
	TickDriver.active = true
	for i in 40:
		await get_tree().physics_frame
	TickDriver.active = false
	await get_tree().physics_frame
	var space := middle.get_world_3d().direct_space_state
	var at := middle.global_position
	var body := middle.get_body_shape()
	var mover := CrowdMover.current
	var lift := mover.max_step + 0.083 * tan(middle.floor_max_angle) # as the batch lifts it for one tick's walk
	var motion := Vector3(0.083, 0, 0) # one tick at 5 m/s
	print("")
	print("[%s]" % label)
	var sweep := PhysicsShapeQueryParameters3D.new()
	sweep.shape = body.shape
	sweep.transform = Transform3D(Basis.IDENTITY, at + body.position + Vector3(0, lift, 0))
	sweep.motion = motion
	sweep.collision_mask = mover.ground_layers
	_row("wall sweep (the crowd mover's: the level only)", func() -> void: space.cast_motion(sweep))
	var with_pawns := PhysicsShapeQueryParameters3D.new()
	with_pawns.shape = sweep.shape
	with_pawns.transform = sweep.transform
	with_pawns.motion = sweep.motion
	with_pawns.collision_mask = mover.ground_layers | 2
	with_pawns.exclude = [middle.get_rid()]
	_row("the same sweep, pawns included (not used; for comparing)", func() -> void: space.cast_motion(with_pawns))
	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = mover.ground_layers
	ray.from = at + motion + Vector3(0, lift, 0)
	ray.to = at + motion - Vector3(0, lift + 0.05, 0)
	_row("ground ray (the crowd mover's)", func() -> void: space.intersect_ray(ray))
	var mask_before := middle.collision_mask
	_row("move_and_slide, colliding with pawns (as every pawn moved before)", func() -> void:
		middle.global_position = at
		middle.velocity = Vector3(5, 0, 0)
		middle.move_and_slide())
	middle.collision_mask = 1
	_row("move_and_slide, the level only", func() -> void:
		middle.global_position = at
		middle.velocity = Vector3(5, 0, 0)
		middle.move_and_slide())
	middle.collision_mask = mask_before
	middle.global_position = at
	# The whole batch: every pawn walking towards the middle, moved by the CrowdMover, put back after each time.
	var starts := PackedVector3Array()
	for pawn in _pawns:
		starts.append(pawn.global_position)
	var rounds := 200
	var started := Time.get_ticks_usec()
	for r in rounds:
		for i in _pawns.size():
			var pawn := _pawns[i]
			var inward := (centre - pawn.global_position)
			inward.y = 0.0
			var step := inward.normalized() * 0.083 if inward.length() > 0.01 else Vector3(0.083, 0, 0)
			pawn.velocity = step * 60.0
			mover.queue_move(pawn, step, 1.0 / 60.0)
		mover._tick_simulate(1.0 / 60.0, 0)
		for i in _pawns.size():
			_pawns[i].global_position = starts[i]
	var per_pawn := (Time.get_ticks_usec() - started) / float(rounds * _pawns.size())
	# Claude 2026-11-16 (audit): the whole of it: the batch, each pawn finishing its tick, and any that fell back to physics.
	print("  %7.2f  the CrowdMover's whole batch, per pawn, with each pawn's finish (%d pawns walking inward; %d handed back to physics last round)" % [per_pawn, _pawns.size(), mover.fallbacks_last_tick])
	for pawn in _pawns:
		pawn.free()
	_pawns.clear()
	TickDriver.active = true


func _row(label: String, work: Callable) -> void:
	var started := Time.get_ticks_usec()
	for i in CALLS:
		work.call()
	print("  %7.2f  %s" % [(Time.get_ticks_usec() - started) / float(CALLS), label])


func _make_box(at: Vector3, size: Vector3, tilt_z: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	body.rotation.z = tilt_z
	add_child(body)
	return body


func _make_pawn(at: Vector3) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	add_child(pawn)
	_pawns.append(pawn)
	return pawn
