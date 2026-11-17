# Written by Claude (claude-opus-5-5), 2026-11-16. History: movement/CHANGELOG.md.
## Moves AI pawns walking on the ground all together once a tick, instead of each one calling Godot's move_and_slide.
##
## A GameMode module (GameMode.crowd_mover), pawn spec 8.22. A pawn the AI drives hands its move for the tick to
## [method try_take_move] and waits; once every pawn has simulated (this runs last in TickDriver's simulate phase) it moves them all
## (flat, pushed apart where they overlap, checked for walls and stood on the ground), then each pawn finishes its tick or, where a
## check failed, moves by physics. With the navcore library the batch runs in C++ ([member use_cpp_batch]: CrowdBatch, on worker
## threads, walls from the nav mesh); without it a GDScript twin uses physics sweeps and rays, and must give the same answer. A player's
## pawn, anything on a client and anything in the air always moves by physics. [member enabled] and [member separation_strength] are in
## the start menu's match options. Diagnostics: "movement.crowd", "movement.crowd_queries" and "movement.crowd_fallbacks" (F4).
class_name CrowdMover
extends GameModeModule

## The CrowdMover in the game, or null if the game has none. Pawns ask this each tick, so it's a static: cheaper than finding the
## module through GameMode.
static var current: CrowdMover = null

## Off: every pawn moves by physics, as before this module.
@export var enabled := true
## How much of an overlap between two pawns is pushed apart each tick: 1 all of it (each of two crowd pawns moves half, the standard
## way crowds are kept apart), less to let them squeeze, 0 none (they walk through each other). Below about 1, two pawns walking
## straight at each other pass through.
@export_range(0.0, 1.0, 0.05) var separation_strength := 1.0
## The gap kept between pawns' capsules, in metres.
@export_range(0.0, 1.0, 0.01, "or_greater") var separation_margin := 0.1
## The fastest a push may move a pawn, in metres a second, so a pawn pressed in from all sides doesn't shoot out. Above a sprint, so
## a pawn walking into another is held back.
@export_range(0.0, 40.0, 0.1, "or_greater") var max_push_speed := 10.0
## How far up or down a pawn may step in one move, in metres, on top of what its slope allows (the pawn's floor_max_angle over the
## distance moved). Beyond it, physics takes over for that pawn. The wall sweep is lifted by the same amount, so whatever is taller
## counts as a wall.
@export_range(0.0, 2.0, 0.01) var max_step := 0.4
## The physics layers that count as ground and walls (the terrain and level geometry; pawns are on layer 2).
@export_flags_3d_physics var ground_layers := 1
## The grid's cell size for finding neighbours, in metres. About twice the widest pawn.
@export_range(0.5, 8.0, 0.25) var cell_size := 2.0
## On: the batch in C++ (CrowdBatch: worker threads, walls from the nav mesh) when the navcore library is there. Off: the GDScript
## batch, with walls from physics sweeps.
@export var use_cpp_batch := true

## Runs after every pawn in TickDriver's simulate phase (pawns register at 0).
const TICK_ORDER := 1000000

## How many pawns it was given on its last tick, and how many of those it handed back to physics (a wall, an edge, no ground, too
## steep, no shape). For tests and diagnostics.
var moved_last_tick := 0
var fallbacks_last_tick := 0

var _driver: Node = null
var _queued: Array[Pawn] = []
var _motions := PackedVector3Array()
var _seconds := PackedFloat32Array()
var _ray := PhysicsRayQueryParameters3D.new()
var _sweep := PhysicsShapeQueryParameters3D.new() # the wall check
var _cpp_batch: Object = null # the C++ batch, made on first use (_get_cpp_batch)

# CrowdBatch's statuses (crowd_batch.h), the same numbers. Written here because the C++ class may not exist.
const BATCH_BY_PHYSICS := 0
const BATCH_MOVED := 1
const BATCH_CHECK_WALLS := 2
const BATCH_CHECK_GROUND := 3


func _init() -> void:
	set_process(false) # no per-frame work: TickDriver calls _tick_simulate
	set_physics_process(false)


func _on_module_added(game_mode: GameModeSingleton) -> void:
	current = self
	game_mode.crowd_mover = self
	_driver = get_node_or_null(^"/root/TickDriver")
	if _driver:
		_driver.register(self, TICK_ORDER)


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	if current == self:
		current = null
	if game_mode.crowd_mover == self:
		game_mode.crowd_mover = null
	if _driver:
		_driver.unregister(self)
	_finish_queued_unmoved()


## Takes this tick's move of a pawn, if it moves that pawn, and returns true; the pawn then waits for finish_crowd_move or
## finish_move_by_physics. False: the pawn moves by physics itself (see the class description for which pawns it moves). seconds is
## the pawn's run length.
func try_take_move(pawn: Pawn, was_grounded: bool, seconds: float) -> bool:
	if not enabled or not pawn.crowd_movement or not was_grounded or pawn.velocity.y > 0.0:
		return false
	if _driver == null or not _driver.is_in_simulate():
		return false
	if not pawn.is_authority() or (pawn.controller_manager and pawn.controller_manager.has_player()):
		return false
	if pawn.ability_manager and pawn.ability_manager.needs_full_movement():
		return false
	queue_move(pawn, pawn.velocity * seconds, seconds)
	return true


## The settings a start menu may offer (GameModeModule.get_match_options).
func get_match_options() -> PackedStringArray:
	return PackedStringArray(["enabled", "separation_strength"])


## Queues a pawn's move for this tick: motion is its velocity times the seconds this run covers. It's moved, and told
## (Pawn.finish_crowd_move), once every pawn has simulated. try_take_move calls this; a test may too.
func queue_move(pawn: Pawn, motion: Vector3, seconds: float) -> void:
	_queued.append(pawn)
	_motions.append(motion)
	_seconds.append(seconds)


## TickDriver's simulate phase, after every pawn: moves everything queued this tick.
func _tick_simulate(_dt: float, tick: int) -> void:
	moved_last_tick = _queued.size()
	fallbacks_last_tick = 0
	if _queued.is_empty():
		return
	var started := PerfScopes.begin()
	# Only pawns still here: one freed during the tick, after handing its move over, is dropped.
	var pawns: Array[Pawn] = []
	var motions := PackedVector3Array()
	var seconds := PackedFloat32Array()
	for i in _queued.size():
		if is_instance_valid(_queued[i]) and _queued[i].is_inside_tree():
			pawns.append(_queued[i])
			motions.append(_motions[i])
			seconds.append(_seconds[i])
	_queued = []
	_motions = PackedVector3Array()
	_seconds = PackedFloat32Array()
	if pawns.is_empty():
		return
	# What the batch needs from each pawn, in one pass: where it stands, its width, its steepest walkable floor (as a rise per metre,
	# and as the least upward normal), and its collision shape and where that sits on it, for the wall sweep.
	var count := pawns.size()
	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	var slopes := PackedFloat32Array()
	var floor_normals := PackedFloat32Array()
	var shapes: Array[Shape3D] = []
	var shape_offsets := PackedVector3Array()
	for pawn in pawns:
		positions.append(pawn.global_position)
		radii.append(pawn.get_body_radius())
		slopes.append(tan(pawn.floor_max_angle))
		floor_normals.append(cos(pawn.floor_max_angle))
		var body := pawn.get_body_shape()
		shapes.append(body.shape if body else null)
		shape_offsets.append(body.position if body else Vector3.ZERO)
	var space := pawns[0].get_world_3d().direct_space_state
	var moved_ok := PackedByteArray() # 1 for each pawn the batch moved, 0 for one it hands back to physics
	moved_ok.resize(count)
	moved_ok.fill(0)
	# In C++ when it can be.
	var cpp_batch := _get_cpp_batch()
	var moved: PackedVector3Array
	if cpp_batch != null:
		moved = _move_batch_cpp(cpp_batch, pawns, positions, motions, radii, seconds, slopes, floor_normals, shapes, shape_offsets, space,
				moved_ok, tick)
	else:
		moved = _move_batch(positions, motions, radii, seconds, slopes, floor_normals, shapes, shape_offsets, _obstacles(pawns), space, moved_ok)
	for i in count:
		if moved_ok[i] == 1:
			pawns[i].finish_crowd_move(moved[i], seconds[i])
		else:
			fallbacks_last_tick += 1
			pawns[i].finish_move_by_physics()
	PerfScopes.end(&"movement.crowd", started)
	if fallbacks_last_tick > 0:
		PerfScopes.add(&"movement.crowd_fallbacks", 0, fallbacks_last_tick)


## Every other living pawn, which the crowd keeps clear of without moving it: [positions, radii].
func _obstacles(movers: Array[Pawn]) -> Array:
	var moving := {}
	for pawn in movers:
		moving[pawn] = true
	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	for node in get_tree().get_nodes_in_group(Pawn.GROUP): # the list of all pawns
		var pawn := node as Pawn
		if pawn == null or moving.has(pawn) or pawn.is_dead():
			continue
		positions.append(pawn.global_position)
		radii.append(pawn.get_body_radius())
	return [positions, radii]


## The GDScript batch, a twin of the C++ CrowdBatch (same answer): where each pawn ends up, with moved_ok[i] set to 1 for each it moved.
## A pawn that fails a check keeps 0 and the caller moves it by physics. Filling moved_ok fills the caller's own array.
# motions: only the flat part is used. slopes, floor_normals: each pawn's steepest walkable floor. shape_offsets: where the shapes sit
# above the feet. obstacles: the other pawns' [positions, radii].
func _move_batch(positions: PackedVector3Array, motions: PackedVector3Array, radii: PackedFloat32Array, seconds: PackedFloat32Array,
		slopes: PackedFloat32Array, floor_normals: PackedFloat32Array, shapes: Array[Shape3D], shape_offsets: PackedVector3Array,
		obstacles: Array, space: PhysicsDirectSpaceState3D, moved_ok: PackedByteArray) -> PackedVector3Array:
	var count := positions.size()
	# 1. Where each would go, flat.
	var wanted := PackedVector3Array()
	wanted.resize(count)
	for i in count:
		wanted[i] = positions[i] + Vector3(motions[i].x, 0.0, motions[i].z)
	# 2. Separation, against everyone: the movers where they'd go, the others where they stand. Every push is worked out from the
	# same positions before any is applied, so the order of the pawns changes nothing.
	var other_positions: PackedVector3Array = obstacles[0]
	var other_radii: PackedFloat32Array = obstacles[1]
	var grid := {}
	var widest := 0.0
	for i in count:
		_add_to_grid(grid, wanted[i], i)
		widest = maxf(widest, radii[i])
	for j in other_positions.size():
		_add_to_grid(grid, other_positions[j], count + j)
		widest = maxf(widest, other_radii[j])
	var pushed := wanted.duplicate()
	for i in count:
		var push := Vector3.ZERO
		var reach := radii[i] + widest + separation_margin
		var span := ceili(reach / cell_size)
		var cell := _cell_of(wanted[i])
		for dx in range(-span, span + 1):
			for dz in range(-span, span + 1):
				var others: Variant = grid.get(cell + Vector2i(dx, dz))
				if others == null:
					continue
				for j: int in others:
					if j == i:
						continue
					var other_at: Vector3 = wanted[j] if j < count else other_positions[j - count]
					var other_radius: float = radii[j] if j < count else other_radii[j - count]
					var apart := Vector2(wanted[i].x - other_at.x, wanted[i].z - other_at.z)
					var needed := radii[i] + other_radius + separation_margin
					var distance := apart.length()
					if distance >= needed:
						continue
					# Exactly on top of each other: a direction from the pair's numbers, so both don't pick the same one.
					var away := apart / distance if distance > 0.0001 else Vector2.from_angle(float(i * 7 + j * 13))
					var share := 0.5 if j < count else 1.0
					push += Vector3(away.x, 0.0, away.y) * (needed - distance) * share * separation_strength
		var most := max_push_speed * seconds[i]
		if push.length() > most:
			push = push.normalized() * most
		pushed[i] = wanted[i] + push
	# 3. Walls (a sweep) and the ground (a ray). moved_ok starts at 0 for every pawn and is set once both checks pass.
	var result := positions.duplicate()
	var queries_started := PerfScopes.begin() # the sweeps and rays alone, to tell them from the GDScript around them (diagnostics)
	for i in count:
		# The checks are in _walls_and_ground, which the C++ batch's hand-backs share.
		var landed: Variant = _walls_and_ground(positions[i], pushed[i], slopes[i], floor_normals[i], shapes[i], shape_offsets[i], space, true)
		if landed != null:
			result[i] = landed
			moved_ok[i] = 1
	PerfScopes.end(&"movement.crowd_queries", queries_started)
	return result


## One pawn's wall and ground checks by physics: where it lands going from [code]from[/code] to [code]to[/code], or null if physics
## must move it instead. With sweep off, only the ground is checked (the C++ batch walked it along the nav mesh already, but couldn't
## tell the ground there).
func _walls_and_ground(from: Vector3, to: Vector3, slope: float, floor_normal: float, shape: Shape3D, shape_offset: Vector3,
		space: PhysicsDirectSpaceState3D, sweep: bool) -> Variant:
	_ray.collision_mask = ground_layers
	_ray.hit_from_inside = false
	_sweep.collision_mask = ground_layers
	var flat := Vector2(to.x - from.x, to.z - from.z).length()
	# How far up it may step over this move: a step plus what its slope allows over the distance.
	var allowed := max_step + flat * slope
	if sweep:
		if shape == null:
			return null # nothing to sweep for walls: physics instead
		if flat > 0.00001:
			# A wall along the way: its own shape swept along the move, lifted by that much, against the level. A fraction under 1 from
			# cast_motion means something is in the way.
			_sweep.shape = shape
			_sweep.transform = Transform3D(Basis.IDENTITY, from + shape_offset + Vector3(0.0, allowed, 0.0))
			_sweep.motion = Vector3(to.x - from.x, 0.0, to.z - from.z)
			var fractions := space.cast_motion(_sweep)
			if fractions.is_empty() or fractions[0] < 1.0:
				return null # a wall: physics instead
	# (Not moving sideways still checks the ground under it: ground taken away, or a pawn lifted off it, falls by physics.)
	# The ground under where it ends up, within that step.
	_ray.from = Vector3(to.x, from.y + allowed, to.z)
	_ray.to = Vector3(to.x, from.y - allowed - 0.05, to.z)
	var ground := space.intersect_ray(_ray)
	if ground.is_empty():
		return null # no ground there, or a drop: physics instead
	var normal: Vector3 = ground["normal"]
	if normal.y < floor_normal:
		return null # too steep to walk on
	var at: Vector3 = ground["position"]
	# (A ray's answer differs from the floor by a hair, 3e-8 m on flat ground. The pawn rounds where it ends up as its rollback
	# recording does, Pawn.finish_crowd_move, so a still pawn still lands exactly where it was.)
	return Vector3(to.x, at.y, to.z)


## The C++ batch, made on first use, or null without the library or with use_cpp_batch off.
## It's given the job scheduler (null: no worker threads), the sight geometry for the ground (null: the ground by physics rays) and
## the NavServer for the walls (null: the walls by physics sweeps).
func _get_cpp_batch() -> Object:
	if not use_cpp_batch or not ClassDB.class_exists(&"CrowdBatch"):
		return null
	if _cpp_batch == null:
		_cpp_batch = ClassDB.instantiate(&"CrowdBatch")
		var nav: Object = Engine.get_singleton(&"NavServer") if Engine.has_singleton(&"NavServer") else null
		_cpp_batch.setup(TickJobs.get_scheduler(), SightGeometryFeeder.get_geometry(), nav)
	return _cpp_batch


## The batch through CrowdBatch (statuses in crowd_batch.h), with physics for the pawns it hands back. Fills moved_ok as _move_batch
## does, and returns where each pawn ends up.
func _move_batch_cpp(cpp_batch: Object, pawns: Array[Pawn], positions: PackedVector3Array, motions: PackedVector3Array,
		radii: PackedFloat32Array, seconds: PackedFloat32Array, slopes: PackedFloat32Array, floor_normals: PackedFloat32Array,
		shapes: Array[Shape3D], shape_offsets: PackedVector3Array, space: PhysicsDirectSpaceState3D, moved_ok: PackedByteArray,
		tick: int) -> PackedVector3Array:
	var tiers := PackedInt32Array()
	for pawn in pawns:
		var navigation := pawn.navigation_manager
		# -1 while crossing a nav link (a jump, or a walk off a ledge), which leaves the nav mesh on purpose, so the batch checks it with
		# physics instead of stopping it at the mesh's edge (crowd_batch.h).
		if navigation and navigation.is_crossing_link():
			tiers.append(-1)
		else:
			tiers.append(navigation.nav_tier if navigation else 0)
	var obstacles := _obstacles(pawns)
	cpp_batch.set_settings(separation_strength, separation_margin, max_push_speed, max_step, ground_layers, cell_size)
	var result: PackedVector3Array = cpp_batch.move(positions, motions, radii, seconds, slopes, floor_normals, tiers, obstacles[0],
			obstacles[1], tick)
	var statuses: PackedByteArray = cpp_batch.get_statuses()
	var queries_started := PerfScopes.begin()
	for i in pawns.size():
		var status := statuses[i]
		if status == BATCH_MOVED:
			moved_ok[i] = 1
		elif status == BATCH_CHECK_WALLS or status == BATCH_CHECK_GROUND:
			var landed: Variant = _walls_and_ground(positions[i], result[i], slopes[i], floor_normals[i], shapes[i], shape_offsets[i], space,
					status == BATCH_CHECK_WALLS)
			if landed != null:
				result[i] = landed
				moved_ok[i] = 1
		# BATCH_BY_PHYSICS: moved_ok stays 0, and the pawn moves by physics.
	PerfScopes.end(&"movement.crowd_queries", queries_started)
	return result


func _cell_of(at: Vector3) -> Vector2i:
	return Vector2i(floori(at.x / cell_size), floori(at.z / cell_size))


func _add_to_grid(grid: Dictionary, at: Vector3, index: int) -> void:
	var cell := _cell_of(at)
	var list: Variant = grid.get(cell)
	if list == null:
		grid[cell] = [index]
	else:
		(list as Array).append(index)


# Pawns queued when the module is taken away mid-tick: they finish where they are, so none is left halfway through a tick.
func _finish_queued_unmoved() -> void:
	for i in _queued.size():
		if is_instance_valid(_queued[i]):
			_queued[i].finish_crowd_move(_queued[i].global_position, _seconds[i])
	_queued.clear()
	_motions.clear()
	_seconds.clear()
