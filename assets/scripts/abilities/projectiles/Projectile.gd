# Written by Claude (claude-opus-5-5), 2026-11-18. History: abilities/CHANGELOG.md.
## A projectile in flight: a networked entity that moves each tick and hits the first pawn (or the ground) in its path.
##
## Fired by a [FireProjectileStep] through [method spawn_from], which spawns it with [method NetworkSession.spawn] (offline too) as a
## type named after its scene. The server, or the offline game, moves it and decides hits: each tick it sweeps its path against pawns
## and the world. Clients draw it from snapshots. A hit goes to the target's AbilityManager like a swing's, carrying the firing ability's
## on-hit effects, so damage, knockback, parries and dash invulnerability work as for melee. It despawns on a hit, on the world, or past
## its range or lifetime. Design: pawn spec 8.24.
## [codeblock]
## Projectile.spawn_from(preload("res://assets/scenes/projectiles/bolt.tscn"), ability, origin, direction)
## [/codeblock]
class_name Projectile
extends Node3D

## Metres a second at launch.
@export_range(0.5, 500.0, 0.5, "or_greater") var speed := 30.0
## Metres a second squared downward; 0 flies straight.
@export var gravity := 0.0
## Radius of the hit sphere swept along its path, in metres.
@export_range(0.01, 5.0, 0.01, "or_greater") var radius := 0.15
## Metres it can fly before it's gone.
@export_range(0.5, 1000.0, 0.5, "or_greater") var max_range := 40.0
## Seconds it can fly before it's gone.
@export_range(0.1, 60.0, 0.1, "or_greater") var max_lifetime := 3.0
## On: the level's solid geometry (world_mask) stops it.
@export var hits_world := true
## The physics layers that stop it (the ground and walls).
@export_flags_3d_physics var world_mask := 1

## Its velocity in metres a second; recorded with its position, so clients can face it along its flight.
var velocity := Vector3.ZERO
## Who fired it, on the server; null on clients or once the shooter is gone.
var shooter: Pawn = null
## The firing pawn's team, which it doesn't hit unless hits_own_team.
var team := 0
## On: it can hit its own team.
var hits_own_team := false

var _effects: Array[Effect] = [] # the firing ability's on-hit effects, copied at launch so a dead shooter's hit still lands
var _attacker_effects: Array[Effect] = []
var _ability: AbilityBase = null
var _travelled := 0.0
var _ticks_left := 0
var _launched := false
var _done := false
var _entity: NetworkEntity = null
var _ray := PhysicsRayQueryParameters3D.new()


## The network type name for a projectile scene.
static func type_name_for(scene: PackedScene) -> String:
	return "projectile:" + scene.resource_path


## Registers a projectile scene as a network type, once. Every machine does it at startup, before hosting or joining: the list of types
## is part of the join check, so one registered later stops new players joining (the faction samples register the bolt).
static func register_scene(scene: PackedScene) -> void:
	var type := type_name_for(scene)
	if NetworkSession.get_type_scene(type) == null:
		NetworkSession.register_type(type, scene)


## Server or offline: fires a projectile from this ability's pawn at origin along direction. Null on a client, or if it couldn't spawn.
static func spawn_from(scene: PackedScene, from_ability: AbilityBase, origin: Vector3, direction: Vector3) -> Projectile:
	if NetworkSession.get_type_scene(type_name_for(scene)) == null:
		if NetworkSession.is_connected_to_session():
			push_warning("[Projectile] %s wasn't registered at startup; registering it now changes the join check" % scene.resource_path)
		register_scene(scene)
	var node := NetworkSession.spawn(type_name_for(scene), 0, origin) as Projectile
	if node:
		node.launch(from_ability, direction)
	return node


## Sets it off from its ability: shooter, team, effects and velocity. spawn_from calls it.
func launch(from_ability: AbilityBase, direction: Vector3) -> void:
	_ability = from_ability
	shooter = from_ability.pawn if from_ability else null
	team = shooter.team if shooter else 0
	if from_ability:
		_effects = from_ability.on_hit_effects.duplicate()
		_attacker_effects = from_ability.on_hit_self_effects.duplicate()
	velocity = direction.normalized() * speed if direction.length_squared() > 0.000001 else Vector3.FORWARD * speed
	_ticks_left = maxi(1, roundi(max_lifetime * TickDriver.get_tick_rate()))
	_launched = true
	_face_flight()


## True once it has hit something or flown its course, on the machine that decides it.
func is_done() -> bool:
	return _done


func _enter_tree() -> void:
	TickDriver.register(self, 10) # after the pawns, so it sweeps where they are this tick


func _exit_tree() -> void:
	TickDriver.unregister(self)


func _ready() -> void:
	for child in get_children():
		if child is NetworkEntity:
			_entity = child


func _process(_delta: float) -> void:
	_face_flight()


func _tick_simulate(dt: float, tick: int) -> void:
	if _done or not _launched or TickDriver.is_resimulating():
		return
	if _entity and _entity.follows_snapshots():
		return # a client: its TickStateComponent places it from snapshots
	if not is_instance_valid(shooter):
		shooter = null # freed mid-flight: a freed object handed to the C++ grid crashes the engine
	var started := PerfScopes.begin() # timed for diagnostics (PerfScopes)
	_fly(dt, tick)
	PerfScopes.end(&"projectile.flight", started)


# One tick of flight: move, sweep for pawns and the world, hit or finish.
func _fly(dt: float, tick: int) -> void:
	var start := global_position
	velocity.y -= gravity * dt
	var end := start + velocity * dt
	var world_hit := false
	if hits_world and is_inside_tree():
		_ray.from = start
		_ray.to = end
		_ray.collision_mask = world_mask
		_ray.collide_with_areas = false
		var found := get_world_3d().direct_space_state.intersect_ray(_ray)
		if not found.is_empty():
			end = found["position"]
			world_hit = true
	var target := _first_pawn_between(start, end, tick)
	if target:
		_hit(target, tick)
		_finish()
		return
	global_position = end
	_travelled += start.distance_to(end)
	_ticks_left -= 1
	if world_hit or _travelled >= max_range or _ticks_left <= 0:
		_finish()


# The first pawn along start -> end that this projectile may hit, or null. Spots every half radius, so a fast projectile leaves no gaps.
func _first_pawn_between(start: Vector3, end: Vector3, tick: int) -> Pawn:
	var length := start.distance_to(end)
	var spots := maxi(1, ceili(length / maxf(radius * 0.5, 0.01)))
	var centres := PackedVector3Array()
	for i in spots + 1:
		centres.append(start.lerp(end, float(i) / spots))
	var touched: Array = []
	if SharedPawnTable.get_grid() != null:
		touched = SharedPawnTable.get_grid().find_touching(centres, radius, shooter, tick)
	else:
		touched = _plain_spheres(centres)
	var best: Pawn = null
	var best_along := INF
	var path := end - start
	for found: Object in touched:
		var other := found as Pawn
		if other == null or other == shooter or other.is_dead():
			continue
		if other.team == team and not hits_own_team:
			continue
		if other.ability_manager and other.ability_manager.is_invulnerable():
			continue # an invulnerable pawn (a dash) is flown through
		var along := (other.global_position - start).dot(path)
		if along < best_along:
			best_along = along
			best = other
	return best


# Without the C++ pawn grid: the same spheres through physics, on the pawns' layer.
func _plain_spheres(centres: PackedVector3Array) -> Array:
	var found: Array = []
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	query.shape = sphere
	query.collision_mask = 2 # pawns are on layer 2 (pawn.tscn)
	if shooter:
		query.exclude = [shooter.get_rid()]
	var space := get_world_3d().direct_space_state
	for centre in centres:
		query.transform = Transform3D(Basis.IDENTITY, centre)
		for hit in space.intersect_shape(query, 8):
			if hit.collider is Pawn and not found.has(hit.collider):
				found.append(hit.collider)
	return found


func _hit(target: Pawn, tick: int) -> void:
	var hit := HitInfo.new()
	hit.attacker = shooter if is_instance_valid(shooter) else null
	hit.target = target
	hit.ability = _ability if is_instance_valid(_ability) else null
	hit.tick = tick
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	hit.direction = flat.normalized() if flat.length_squared() > 0.0001 else Vector3.FORWARD
	hit.effects = _effects
	hit.attacker_effects = _attacker_effects
	if target.ability_manager:
		target.ability_manager.receive_hit(hit)


# Gone everywhere: despawned through the session (offline too), which removes it from every machine.
func _finish() -> void:
	_done = true
	if _entity and _entity.entity_id >= 0:
		NetworkSession.despawn(_entity.entity_id)
	else:
		queue_free()


func _face_flight() -> void:
	var visual := get_node_or_null(^"Visual") as Node3D
	if visual and velocity.length_squared() > 0.0001:
		var forward := velocity.normalized()
		visual.basis = Basis.looking_at(forward, Vector3.UP if absf(forward.y) < 0.999 else Vector3.FORWARD)
