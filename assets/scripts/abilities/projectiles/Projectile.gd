# Written by Claude (claude-opus-5-5), 2026-11-18. History: abilities/CHANGELOG.md.
## A projectile in flight: a networked entity whose flight is worked out from its launch, hitting pawns (up to max_hits) and the ground.
##
## A designer makes only a [ProjectileDefinition]; this built-in projectile ([constant SCENE], registered with [method register])
## carries the networking and builds its look from the definition; code of its own (homing) means a scene extending this, registered
## with [method register_scene]. Fired by a [FireProjectileStep] through [method fire]. Its state is a launch record set once, so nothing
## is sent while it flies; clients draw the flight themselves. The server sweeps each tick's stretch of flight through the same hit
## system as a swing ([HitQuery], its own [HitRun]), with lag compensation for its first ticks. A shooter that's gone lands no hits,
## unless its hit definition's lands_without_source is on. Details: the abilities README. Design: ability spec 9, pawn spec 8.24.
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
## It met something, where it decides hits: one entry of its [member hit_run]'s log (see [method HitRun.entry]), hit or not.
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
## The tick it ends unless a pawn stops it first, worked out at launch: where it meets the world, or runs out of range or lifetime. -1
## before launch.
var end_tick := -1
## Where it ends then: so a client shows the impact exactly there.
var end_point := Vector3.ZERO
## The firing pawn's entity id; -1 for a pawn not spawned through the session.
var shooter_id := -1

## The firing pawn's team: its allies, for the whitelist.
var team := 0
## What it has hit and met, where it decides hits (see [method HitRun.entry]); null on a client.
var hit_run: HitRun = null
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
@warning_ignore("unused_private_class_variable") # read and written by name, by its HitRun
var _hit_keys := PackedInt64Array() # the pawns it has hit (entity numbers): its hit run's list
var _cleared_shooter := false # it has left the shooter's body, so the shooter can be hit (hits_self)
var _view_delay := 0.0 # how far behind the shooter saw other pawns when it fired, in ticks
var _ends_at_world := false # end_tick is the world's, not range or lifetime (server)
var _world_normal := Vector3.UP
var _impact_shown := false # a client: shown at end_point already
var _launched := false
var _done := false
var _entity: NetworkEntity = null
var _flight: ProjectileDefinition = null
var _flight_index := -2 # the definition_index _flight was worked out for
var _heard_launch := false # a client: launched was sent

## The group every projectile is in, for tools that find them (the diagnostics' projectile trace).
const GROUP := &"projectiles"
## Ticks a step of the world trace at launch covers, for an arc.
const COARSE_TICKS := 6


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
## is part of the join check, so one registered later stops new players joining.
static func register_scene(scene: PackedScene) -> void:
	var type := type_name_for(scene)
	if NetworkSession.get_type_scene(type) == null:
		NetworkSession.register_type(type, scene)


## Server or offline: fires a projectile with this definition from this ability's pawn, at origin along direction, hitting with the
## ability's hit definition or the one given. The built-in one, or a scene of its own if given. Null on a client, or if it couldn't spawn.
static func fire(from_ability: AbilityBase, origin: Vector3, direction: Vector3, flies_with: ProjectileDefinition,
		scene: PackedScene = null, hits_with: HitDefinition = null) -> Projectile:
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
		node.launch(from_ability, origin, direction, flies_with, hits_with)
	return node


## Sets it off from its ability: the launch record, the shooter's id and team, and its hit run. fire() calls it.
func launch(from_ability: AbilityBase, origin: Vector3, direction: Vector3, flies_with: ProjectileDefinition = null,
		hits_with: HitDefinition = null) -> void:
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
	hit_run = HitRun.new(self, &"_hit_keys")
	hit_run.team = team
	hit_run.on_intersect = func(entry: Dictionary) -> void:
		intersected.emit(self, entry)
		if entry.hit and entry.kind == HitRun.Kind.PAWN:
			hit_pawn.emit(self, entry.target, entry.point)
	if from_ability:
		_view_delay = from_ability.view_ticks_behind()
		hit_run.ability = from_ability
		hit_run.hit = hits_with.resolved() as HitDefinition if hits_with else from_ability.hit_definition()
	elif hits_with:
		hit_run.hit = hits_with.resolved() as HitDefinition
	if hit_run.hit and hit_run.hit.lands_without_source:
		hit_run.remember_source(from_ability)
	launch_origin = origin
	launch_direction = direction.normalized() if direction.length_squared() > 0.000001 else Vector3.FORWARD
	launch_tick = TickDriver.tick
	global_position = origin
	_plan_end()
	if from_pawn:
		from_pawn.linger_until(launch_tick + end_tick) # a removed shooter stays until this ends, so its hits keep their ability
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


## Where it is this many ticks after launch (a fraction is between ticks), from its launch record. Hitscan: along its tracer, from the
## muzzle to where it ended.
func position_at(age: float) -> Vector3:
	if flight().hitscan:
		return launch_origin.lerp(end_point, clampf(age / float(maxi(end_tick, 1)), 0.0, 1.0))
	return launch_origin + flight().offset_at(launch_direction, age)


## Its velocity this many ticks after launch.
func velocity_at(age: float) -> Vector3:
	if flight().hitscan:
		return (end_point - launch_origin) * float(TickDriver.get_tick_rate()) / float(maxi(end_tick, 1))
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
		if not _done and not is_own_shot() and not _impact_shown:
			flight().spawn_impact(get_parent(), global_position) # a client, stopped by a pawn: where it was drawn last
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
			if end_tick >= 0 and age >= end_tick:
				# Its end, known from launch: there exactly, with its impact, though the despawn comes a little later.
				global_position = end_point
				if visual:
					visual.visible = false
				if not _impact_shown:
					_impact_shown = true
					flight().spawn_impact(get_parent(), end_point)
			else:
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
	if settings.hitscan:
		if age >= end_tick:
			global_position = end_point
			_finish() # its hits were all made as it was fired; the tracer has shown
		return
	var start := position_at(age - 1)
	var ending := age >= end_tick
	var end := end_point if ending else position_at(age) # the world, range and lifetime were worked out at launch
	var spent := false
	if hit_run.hit:
		var centres := HitQuery.line_centres(start, end, settings.radius)
		var from_pawn := shooter
		# For its first ticks, as the shooter saw other pawns, by less each tick (lag compensation, ability spec 9.1).
		var touched := HitQuery.touching(centres, settings.radius, tick, from_pawn, _view_delay - float(age - 1), hit_run.hit.hits_self)
		if from_pawn and hit_run.hit.hits_self and not _cleared_shooter:
			# It starts inside or beside the shooter: the shooter can be met once it has flown clear of it.
			if touched.has(from_pawn):
				touched.erase(from_pawn)
			else:
				_cleared_shooter = true
		spent = hit_run.meet_pawns(touched, tick, from_pawn, start, end, end - start)
	if spent:
		global_position = hit_run.last_point # stopped in the pawn it met
		_finish()
		return
	global_position = end
	if ending and _ends_at_world:
		hit_run.meet_world(tick, end, _world_normal)
		hit_world.emit(self, end, _world_normal)
	if ending or hit_run.is_spent():
		_finish()


# Hitscan, on the tick it's fired: a straight line to its range, cut by the world, checked for pawns as the shooter saw them (its whole
# view delay: the classic lag compensation for hitscan), met and hit through its hit run. The tracer then shows for tracer_ticks.
func _resolve_hitscan(settings: ProjectileDefinition) -> void:
	end_tick = settings.tracer_ticks()
	end_point = launch_origin + launch_direction * settings.max_range
	_ends_at_world = false
	if settings.hits_world and is_inside_tree():
		var ray := PhysicsRayQueryParameters3D.create(launch_origin, end_point, settings.world_mask)
		var found := get_world_3d().direct_space_state.intersect_ray(ray)
		if not found.is_empty():
			end_point = found["position"]
			_ends_at_world = true
			_world_normal = found["normal"]
	if hit_run == null or hit_run.hit == null or _entity and _entity.follows_snapshots():
		return
	var touched := HitQuery.touching(HitQuery.line_centres(launch_origin, end_point, settings.radius), settings.radius, launch_tick, shooter, _view_delay, false)
	if hit_run.meet_pawns(touched, launch_tick, shooter, launch_origin, end_point, end_point - launch_origin):
		end_point = hit_run.last_point # stopped in the pawn it met
		_ends_at_world = false
	elif _ends_at_world:
		hit_run.meet_world(launch_tick, end_point, _world_normal)
		hit_world.emit(self, end_point, _world_normal)


# Works out at launch where and when it ends unless a pawn stops it: past its range or lifetime, or where its path meets the world. The
# world is traced once, here, not every tick: one ray for a straight flight, coarse steps then each tick of the step that meets it for
# an arc. Geometry that appears later (a door closing, terrain streaming in) isn't seen.
func _plan_end() -> void:
	var settings := flight()
	if settings.hitscan:
		_resolve_hitscan(settings)
		return
	var life := settings.lifetime_ticks()
	end_tick = life
	end_point = position_at(life)
	_ends_at_world = false
	var travelled := 0.0
	var previous := launch_origin
	for age in range(1, life + 1):
		var at := position_at(age)
		travelled += previous.distance_to(at)
		previous = at
		if travelled >= settings.max_range:
			end_tick = age
			end_point = at
			break
	if not settings.hits_world or not is_inside_tree():
		return
	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = settings.world_mask
	ray.collide_with_areas = false
	var space := get_world_3d().direct_space_state
	var step := end_tick if settings.drop_per_second_squared() == 0.0 else COARSE_TICKS # a straight flight is one ray
	var from_age := 0
	while from_age < end_tick:
		var to_age := mini(from_age + step, end_tick)
		ray.from = position_at(from_age)
		ray.to = position_at(to_age)
		if not space.intersect_ray(ray).is_empty():
			# Met in this stretch: find the tick, one tick at a time.
			for age in range(from_age + 1, to_age + 1):
				ray.from = position_at(age - 1)
				ray.to = position_at(age)
				var found := space.intersect_ray(ray)
				if not found.is_empty():
					end_tick = age
					end_point = found["position"]
					_ends_at_world = true
					_world_normal = found["normal"]
					return
		from_age = to_age


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
