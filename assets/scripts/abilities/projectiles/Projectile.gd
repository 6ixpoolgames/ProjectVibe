# Written by Claude (claude-opus-5-5), 2026-11-18. History: abilities/CHANGELOG.md.
## A projectile in flight: a networked entity whose flight is worked out from its launch, hitting pawns (up to max_hits) and the ground.
##
## A designer makes only a [ProjectileDefinition] (numbers, a visual scene, an impact scene); this built-in projectile
## ([constant SCENE], registered once with [method register]) carries the networking and builds its look from the definition. Code of
## its own (homing) means a scene whose root extends this, registered with [method register_scene].
## [br][br]Fired by a [FireProjectileStep] through [method fire], which spawns it with [method NetworkSession.spawn] (offline too). Its state is a launch record (tick, origin, velocity, definition, shooter's entity id), set once and
## never changed in flight, so nothing is sent while it flies (ability spec 9). Where it is at any tick follows from that record and its
## [ProjectileDefinition]; clients draw the flight themselves. The server (or the offline game) sweeps each tick's stretch of flight
## for hits, made and delivered as a swing's are ([method HitInfo.make]), carrying the firing ability's on-hit effects, so damage,
## knockback, parries and dash invulnerability work as for melee. Each pawn is hit once; it stops at max_hits, the world, or past its
## range or lifetime. For its first ticks of flight, hits are checked against where the shooter saw other pawns (lag compensation).
## [br][br]Visual hooks, apart from the ability's: [signal launched], [signal hit_pawn], [signal hit_world] and [signal ended], and its
## definition's impact_scene where it ends. Hits are only known where they're decided, so a client hears launched and ended.
## Design: ability spec 9, pawn spec 8.24.
## [codeblock]
## Projectile.register()     # at startup, on every machine, before hosting or joining
## Projectile.fire(ability, origin, direction, preload("res://assets/scripts/resources/abilities/bolt.tres"))
## [/codeblock]
class_name Projectile
extends Node3D

## It was fired (on a client, once its launch record arrives).
signal launched(projectile: Projectile)
## It hit a pawn, where it decides hits (the server or offline).
signal hit_pawn(projectile: Projectile, target: Pawn, at: Vector3)
## It hit the world, where it decides hits.
signal hit_world(projectile: Projectile, at: Vector3, normal: Vector3)
## It's gone, at this point: on every machine, as it leaves.
signal ended(projectile: Projectile, at: Vector3)
## It met something, where it decides hits: one entry of [member intersections], recorded whether or not the whitelist lets it hit.
signal intersected(projectile: Projectile, entry: Dictionary)

## Its flight and hits when its launch names none: for a scene of its own. The built-in projectile is always given one at launch.
@export var definition: ProjectileDefinition

# The launch record: set once by launch(), recorded and sent (the scene's TickState), never changed in flight.
## The tick it was fired on; -1 before it's launched.
var launch_tick := -1
## Where it was fired from.
var launch_origin := Vector3.ZERO
## The way it was fired, length 1.
var launch_direction := Vector3.FORWARD
## The [DefinitionRegistry] index of the definition it flies with (for an embedded variant, the nearest file it's based on); -1: its own
## [member definition].
var definition_index := -1
## Its speed and gravity scale as fired, so a client flies it the same when it was fired with a variant that changes them.
var launch_speed := 0.0
var launch_gravity_scale := 0.0
## The firing pawn's entity id; -1 for a pawn not spawned through the session.
var shooter_id := -1

## The firing pawn's team: its allies, for the whitelist.
var team := 0
## Everything it met while flying, in order, where it decides hits: {"tick", "kind" (&"pawn" or &"world"), "target" (a Pawn or null),
## "key" (the pawn's id), "point", "normal" (the world's), "hit" (true if the whitelist let it hit)}. Each pawn once.
var intersections: Array[Dictionary] = []
## Who fired it, worked out from its id on the machine that decides hits; null once the shooter is gone.
var shooter: Pawn:
	get:
		return _find_shooter()
## Its velocity now, in metres a second.
var velocity: Vector3:
	get:
		return velocity_at(_age_now())

# Its settings, read from the definition it flies with.
## Metres a second at launch.
var speed: float:
	get:
		return flight().speed
## The hit sphere's radius, in metres.
var radius: float:
	get:
		return flight().radius
## Metres it can fly.
var max_range: float:
	get:
		return flight().max_range

var _shooter_instance := 0 # the shooter's instance id, for a shooter with no entity id
var _ability_index := -1 # the firing ability's place under its AbilityManager
var _effect_ids := PackedInt64Array() # the firing ability's on-hit effects, by id, so a dead shooter's hit still lands
var _attacker_effect_ids := PackedInt64Array()
var _seen_keys := PackedInt64Array() # the pawns it has met (entity ids, else instance ids), so each is met once
var _hits := 0 # the pawns it has hit
var _cleared_shooter := false # it has left the shooter's body, so the shooter can be hit (hits_shooter)
var _view_delay := 0.0 # how far behind the shooter saw other pawns when it fired, in ticks
var _travelled := 0.0
var _launched := false
var _done := false
var _entity: NetworkEntity = null
var _ray := PhysicsRayQueryParameters3D.new()
var _flight: ProjectileDefinition = null
var _flight_index := -2 # the definition_index _flight was worked out for
var _heard_launch := false # a client: launched was sent

## The group every projectile is in, for tools that find them (the diagnostics' projectile trace).
const GROUP := &"projectiles"


## The built-in projectile: a Projectile with its TickStateComponent and NetworkEntity, whose look comes from its definition.
const SCENE := "res://assets/scenes/projectiles/projectile.tscn"
## Its network type's name.
const TYPE := "projectile"


## Registers the built-in projectile as a network type, once. Every machine does it at startup, before hosting or joining: the list of
## types is part of the join check, so one registered later stops new players joining.
static func register() -> void:
	if NetworkSession.get_type_scene(TYPE) == null:
		NetworkSession.register_type(TYPE, load(SCENE))


## The network type name for a projectile scene of its own.
static func type_name_for(scene: PackedScene) -> String:
	return "projectile:" + scene.resource_path


## Registers a projectile scene of its own (code of its own) as a network type, once. Every machine does it at startup, before hosting or joining: the list of types
## is part of the join check, so one registered later stops new players joining (the faction samples register the bolt).
static func register_scene(scene: PackedScene) -> void:
	var type := type_name_for(scene)
	if NetworkSession.get_type_scene(type) == null:
		NetworkSession.register_type(type, scene)


## Server or offline: fires a projectile with this definition from this ability's pawn, at origin along direction. The built-in one,
## or a scene of its own if given. Null on a client, or if it couldn't spawn.
static func fire(from_ability: AbilityBase, origin: Vector3, direction: Vector3, flies_with: ProjectileDefinition,
		scene: PackedScene = null) -> Projectile:
	var type := type_name_for(scene) if scene else TYPE
	if NetworkSession.get_type_scene(type) == null:
		if NetworkSession.is_connected_to_session():
			push_warning("[Projectile] %s wasn't registered at startup; registering it now changes the join check" % type)
		if scene:
			register_scene(scene)
		else:
			register()
	var node := NetworkSession.spawn(type, 0, origin) as Projectile
	if node:
		node.launch(from_ability, origin, direction, flies_with)
	return node


## Sets it off from its ability: the launch record, the shooter's id, team and effects. fire() calls it.
func launch(from_ability: AbilityBase, origin: Vector3, direction: Vector3, flies_with: ProjectileDefinition = null) -> void:
	if flies_with:
		definition_index = DefinitionRegistry.nearest_index(flies_with)
		_flight = flies_with.resolved() as ProjectileDefinition
		_flight_index = definition_index
		if definition_index < 0 and NetworkSession.is_connected_to_session():
			push_warning("[Projectile] %s isn't based on a definition file in the registry, so clients draw it with the scene's own" % flies_with.describe())
	var settings := flight()
	launch_speed = settings.speed
	launch_gravity_scale = settings.gravity_scale
	var from_pawn: Pawn = from_ability.pawn if from_ability else null
	if from_pawn:
		var entity := from_pawn.get_network_entity()
		shooter_id = entity.entity_id if entity else -1
		_shooter_instance = from_pawn.get_instance_id()
		team = from_pawn.team
	if from_ability:
		_ability_index = from_ability.get_index()
		_view_delay = from_ability.view_ticks_behind()
		for effect in from_ability.on_hit_effects:
			_effect_ids.append(effect.get_id())
		for effect in from_ability.on_hit_self_effects:
			_attacker_effect_ids.append(effect.get_id())
	for effect in settings.on_hit_effects:
		if effect:
			effect.register() # so its id finds it
			_effect_ids.append(effect.get_id())
	launch_origin = origin
	launch_direction = direction.normalized() if direction.length_squared() > 0.000001 else Vector3.FORWARD
	launch_tick = TickDriver.tick
	global_position = origin
	_launched = true
	_face_flight()
	_build_visual()
	launched.emit(self)


## The definition it flies with, worked out: the one its launch names, else its own, else the defaults; with the launch's speed and gravity
## scale where they differ (a variant's).
func flight() -> ProjectileDefinition:
	if _flight == null or _flight_index != definition_index:
		_flight_index = definition_index
		var chosen: Definition = DefinitionRegistry.find(definition_index) if definition_index >= 0 else null
		if not chosen is ProjectileDefinition:
			chosen = definition if definition else ProjectileDefinition.new()
		_flight = chosen.resolved() as ProjectileDefinition
		if launch_speed > 0.0 and (_flight.speed != launch_speed or _flight.gravity_scale != launch_gravity_scale):
			_flight = _flight.duplicate() as ProjectileDefinition
			_flight.speed = launch_speed
			_flight.gravity_scale = launch_gravity_scale
	return _flight


## Where it is this many ticks after launch (a fraction is between ticks), from its launch record.
func position_at(age: float) -> Vector3:
	return launch_origin + flight().offset_at(launch_direction, age)


## Its velocity this many ticks after launch.
func velocity_at(age: float) -> Vector3:
	return flight().velocity_at(launch_direction, age)


## True once it has hit something or flown its course, on the machine that decides it.
func is_done() -> bool:
	return _done


## True if it was fired by the pawn this machine predicts: the shooter's own client, which draws its predicted copy instead.
func is_own_shot() -> bool:
	if shooter_id < 0 or not NetworkSession.is_client():
		return false
	var entity := NetworkSession.get_entity(shooter_id)
	return entity != null and entity.role == NetworkEntity.Role.LOCAL_PREDICTED


func _enter_tree() -> void:
	TickDriver.register(self, 10) # after the pawns, so it sweeps where they are this tick
	add_to_group(GROUP)


func _exit_tree() -> void:
	TickDriver.unregister(self)
	if launch_tick >= 0:
		ended.emit(self, global_position)
		if not _done and not is_own_shot():
			flight().spawn_impact(get_parent(), global_position) # a client: where it was drawn last
	PredictedProjectile.server_shot_ended(shooter_id, launch_tick) # the shooter's predicted copy goes with it


func _ready() -> void:
	for child in get_children():
		if child is NetworkEntity:
			_entity = child


func _process(_delta: float) -> void:
	if _entity and _entity.follows_snapshots():
		# A client draws the flight from the launch record, at the tick it draws other entities at.
		var visual := get_node_or_null(^"Visual") as Node3D
		var age := _age_now()
		var shown := launch_tick >= 0 and age >= 0.0 and not is_own_shot()
		if visual:
			visual.visible = shown
		if shown:
			if not _heard_launch:
				_heard_launch = true
				_build_visual()
				launched.emit(self)
			global_position = position_at(age)
	_face_flight()


func _tick_simulate(_dt: float, tick: int) -> void:
	if _done or not _launched or TickDriver.is_resimulating():
		return
	if _entity and _entity.follows_snapshots():
		return # a client: it draws the flight, the server decides hits
	var started := PerfScopes.begin() # timed for diagnostics (PerfScopes)
	_fly(tick)
	PerfScopes.end(&"projectile.flight", started)


# One tick of flight: the stretch from the last tick to this one, checked against the world and pawns.
func _fly(tick: int) -> void:
	var age := tick - launch_tick
	if age < 1:
		return # fired this tick: it leaves the muzzle on the next
	var settings := flight()
	var start := position_at(age - 1)
	var end := position_at(age)
	var world_hit := false
	var world_normal := Vector3.UP
	if settings.hits_world and is_inside_tree():
		_ray.from = start
		_ray.to = end
		_ray.collision_mask = settings.world_mask
		_ray.collide_with_areas = false
		var found := get_world_3d().direct_space_state.intersect_ray(_ray)
		if not found.is_empty():
			end = found["position"]
			world_hit = true
			world_normal = found["normal"]
	var path := end - start
	for target in _pawns_met(start, end, tick, age):
		var along := clampf((target.global_position - start).dot(path) / maxf(path.length_squared(), 0.000001), 0.0, 1.0)
		var at := start + path * along
		var allowed := _whitelisted(target, settings)
		_seen_keys.append(HitInfo.key_of(target))
		_record({"tick": tick, "kind": &"pawn", "target": target, "key": HitInfo.key_of(target), "point": at, "normal": Vector3.ZERO, "hit": allowed})
		if allowed:
			_hit(target, tick, at)
			_hits += 1
		if (allowed and settings.max_hits > 0 and _hits >= settings.max_hits) or _intersects_used_up(settings):
			global_position = at # stopped in the pawn it met
			_finish()
			return
	global_position = end
	_travelled += start.distance_to(end)
	if world_hit:
		_record({"tick": tick, "kind": &"world", "target": null, "key": -1, "point": end, "normal": world_normal, "hit": true})
		hit_world.emit(self, end, world_normal)
	if world_hit or _intersects_used_up(settings) or _travelled >= settings.max_range or age >= settings.lifetime_ticks():
		_finish()


# The pawns along start -> end it hasn't met yet, nearest first, hit or not by the whitelist. Spots every half radius, so a fast
# projectile leaves no gaps. Dead and invulnerable pawns aren't met (a dashing pawn is flown through, and can be met later). For its
# first ticks it checks where the shooter saw them, by less each tick (lag compensation, ability spec 9).
func _pawns_met(start: Vector3, end: Vector3, tick: int, age: int) -> Array[Pawn]:
	var settings := flight()
	var length := start.distance_to(end)
	var spots := maxi(1, ceili(length / maxf(settings.radius * 0.5, 0.01)))
	var centres := PackedVector3Array()
	for i in spots + 1:
		centres.append(start.lerp(end, float(i) / spots))
	var from_pawn := shooter
	var leave_out: Pawn = null if settings.hits_shooter else from_pawn # the shooter isn't met unless it can be hit
	var touched: Array = []
	var shooter_entity: NetworkEntity = from_pawn.get_network_entity() if from_pawn else null
	var back := _view_delay - float(age - 1)
	if back > 0.0 and shooter_entity and shooter_entity.session and LagCompensation.would_rewind(shooter_entity, back):
		var spheres: Array[Vector3] = []
		spheres.assign(centres)
		for entity in LagCompensation.melee_spheres(shooter_entity, spheres, settings.radius, back):
			touched.append(entity.get_parent())
	elif SharedPawnTable.get_grid() != null:
		touched = SharedPawnTable.get_grid().find_touching(centres, settings.radius, leave_out, tick)
	else:
		touched = _plain_spheres(centres, leave_out)
	if from_pawn and settings.hits_shooter and not _cleared_shooter:
		# It starts inside or beside the shooter: the shooter can be met once it has flown clear of it.
		if touched.has(from_pawn):
			touched.erase(from_pawn)
		else:
			_cleared_shooter = true
	var out: Array[Pawn] = []
	var along_of := {}
	var path := end - start
	for found: Object in touched:
		var other := found as Pawn
		if other == null or (other == from_pawn and not settings.hits_shooter) or other.is_dead() or _seen_keys.has(HitInfo.key_of(other)):
			continue
		if other.ability_manager and other.ability_manager.is_invulnerable():
			continue
		along_of[other] = (other.global_position - start).dot(path)
		out.append(other)
	out.sort_custom(func(a: Pawn, b: Pawn) -> bool: return along_of[a] < along_of[b])
	return out


# The whitelist: whether it may hit this pawn (its definition's hits_shooter, hits_allies, hits_enemies).
func _whitelisted(target: Pawn, settings: ProjectileDefinition) -> bool:
	if target == shooter:
		return settings.hits_shooter
	return settings.hits_allies if target.team == team else settings.hits_enemies


func _record(entry: Dictionary) -> void:
	intersections.append(entry)
	intersected.emit(self, entry)


func _intersects_used_up(settings: ProjectileDefinition) -> bool:
	return settings.max_intersects > 0 and intersections.size() >= settings.max_intersects


# Without the C++ pawn grid: the same spheres through physics, on the pawns' layer.
func _plain_spheres(centres: PackedVector3Array, from_pawn: Pawn) -> Array:
	var found: Array = []
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = flight().radius
	query.shape = sphere
	query.collision_mask = 2 # pawns are on layer 2 (pawn.tscn)
	if from_pawn:
		query.exclude = [from_pawn.get_rid()]
	var space := get_world_3d().direct_space_state
	for centre in centres:
		query.transform = Transform3D(Basis.IDENTITY, centre)
		for hit in space.intersect_shape(query, 8):
			if hit.collider is Pawn and not found.has(hit.collider):
				found.append(hit.collider)
	return found


# The same hit a swing makes (HitInfo.make), pushing along its flight, with the effects it was fired with.
func _hit(target: Pawn, tick: int, at: Vector3) -> void:
	var from_pawn := shooter
	var by: AbilityBase = null
	if from_pawn and from_pawn.ability_manager and _ability_index >= 0 and _ability_index < from_pawn.ability_manager.get_child_count():
		by = from_pawn.ability_manager.get_child(_ability_index) as AbilityBase
	HitInfo.make(from_pawn, by, target, velocity_at(tick - launch_tick), tick, _effects_of(_effect_ids), _effects_of(_attacker_effect_ids)).deliver()
	hit_pawn.emit(self, target, at)


func _effects_of(ids: PackedInt64Array) -> Array[Effect]:
	var out: Array[Effect] = []
	for id in ids:
		var effect := Effect.find(id)
		if effect:
			out.append(effect)
	return out


func _find_shooter() -> Pawn:
	if shooter_id >= 0:
		var entity := NetworkSession.get_entity(shooter_id)
		if entity and is_instance_valid(entity):
			return entity.get_parent() as Pawn
	if _shooter_instance != 0 and is_instance_id_valid(_shooter_instance):
		return instance_from_id(_shooter_instance) as Pawn
	return null


# Ticks since launch now: at the tick it draws others at on a client, between ticks for smooth drawing; the tick itself elsewhere.
func _age_now() -> float:
	if launch_tick < 0:
		return 0.0
	if _entity and _entity.follows_snapshots() and NetworkSession.render_tick >= 0.0:
		return NetworkSession.render_tick + TickDriver.get_interpolation_fraction() - launch_tick
	return float(TickDriver.tick - launch_tick)


# Gone everywhere: despawned through the session (offline too), which removes it from every machine. Its impact shows where it ended.
func _finish() -> void:
	_done = true
	flight().spawn_impact(get_parent(), global_position)
	if _entity and _entity.entity_id >= 0:
		NetworkSession.despawn(_entity.entity_id)
	else:
		queue_free()


# Its look, from its definition's visual_scene, unless its scene has a Visual of its own.
func _build_visual() -> void:
	if get_node_or_null(^"Visual") != null or flight().visual_scene == null:
		return
	var visual := flight().visual_scene.instantiate() as Node3D
	if visual:
		visual.name = "Visual"
		add_child(visual)


func _face_flight() -> void:
	var visual := get_node_or_null(^"Visual") as Node3D
	var moving := velocity
	if visual and moving.length_squared() > 0.0001:
		var forward := moving.normalized()
		visual.basis = Basis.looking_at(forward, Vector3.UP if absf(forward.y) < 0.999 else Vector3.FORWARD)
