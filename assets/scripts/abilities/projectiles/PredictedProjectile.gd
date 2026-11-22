# Written by Claude (claude-opus-5-5), 2026-11-22. History: abilities/CHANGELOG.md.
## The shooter's own client's copy of its projectile, drawn the moment it fires (ability spec 9): a visual, with no hits.
##
## The server's projectile reaches the shooter a round trip late, so the shooter's client flies this copy from the same launch, at its
## own predicted tick, and hides the server's ([method Projectile.is_own_shot]). It stops where it meets the world or another pawn, and
## goes when the server's projectile ends ([method server_shot_ended]), or a while after its lifetime if that never comes (a shot the
## server didn't fire).
class_name PredictedProjectile
extends Node3D

## Seconds it waits past its lifetime for the server's projectile to end before it goes anyway.
const GRACE_SECONDS := 2.0

# Live copies by shooter entity id and launch tick, so the server's projectile finds its copy.
static var _live := {}

var launch_tick := 0
var launch_origin := Vector3.ZERO
var launch_direction := Vector3.FORWARD
var flight: ProjectileDefinition = null
var shooter: Pawn = null
## On: it stops where it meets another pawn, as a shot whose hit definition stops at the first does.
var stops_at_first_pawn := true
var _key := ""
var _stopped := false
var _hitscan_end := Vector3.ZERO # hitscan: where its tracer ends, traced here at once
var _last := Vector3.ZERO
var _ray := PhysicsRayQueryParameters3D.new()
var _sphere_query := PhysicsShapeQueryParameters3D.new()


## Fires the shooter's copy of a shot: its definition's visual (or a scene of its own's Visual), flown from origin along direction.
## Null if there's nothing to draw.
static func fire(flies_with: ProjectileDefinition, scene: PackedScene, from_pawn: Pawn, origin: Vector3, direction: Vector3, tick: int,
		stops_at_first_pawn := true) -> PredictedProjectile:
	var settings: ProjectileDefinition = flies_with
	var visual: Node3D = null
	if scene:
		var template := scene.instantiate() as Projectile # never enters the tree, so it registers nothing with the session
		visual = template.get_node_or_null(^"Visual") as Node3D
		if settings == null:
			settings = template.definition
		if visual:
			template.remove_child(visual)
		template.free()
	if settings == null:
		settings = ProjectileDefinition.new()
	if visual == null and settings.visual_scene:
		visual = settings.visual_scene.instantiate() as Node3D
	if visual == null:
		return null
	var copy := PredictedProjectile.new()
	copy.name = "PredictedShot"
	copy.add_child(visual)
	copy.flight = settings.resolved() as ProjectileDefinition
	copy.shooter = from_pawn
	copy.launch_tick = tick
	copy.stops_at_first_pawn = stops_at_first_pawn
	copy.launch_origin = origin
	copy.launch_direction = direction.normalized() if direction.length_squared() > 0.000001 else Vector3.FORWARD
	if copy.flight.hitscan:
		copy._hitscan_end = copy._trace_hitscan(origin, copy.launch_direction, from_pawn)
	var entity := from_pawn.get_network_entity()
	copy._key = "%d:%d" % [entity.entity_id if entity else -1, tick]
	from_pawn.get_parent().add_child(copy)
	copy.global_position = origin
	copy._last = origin
	_live[copy._key] = copy
	return copy


## The server's projectile for this shot ended: its copy goes.
static func server_shot_ended(shooter_id: int, tick: int) -> void:
	var key := "%d:%d" % [shooter_id, tick]
	var copy: PredictedProjectile = _live.get(key)
	if copy and is_instance_valid(copy):
		copy.queue_free()
	_live.erase(key)


func _exit_tree() -> void:
	if _live.get(_key) == self:
		_live.erase(_key)


func _process(_delta: float) -> void:
	var rate := float(TickDriver.get_tick_rate())
	var age := TickDriver.tick + TickDriver.get_interpolation_fraction() - launch_tick
	if age > flight.max_lifetime * rate + GRACE_SECONDS * rate:
		queue_free()
		return
	if _stopped:
		return
	if flight.hitscan:
		var tracer := float(flight.tracer_ticks())
		global_position = launch_origin.lerp(_hitscan_end, clampf(age / tracer, 0.0, 1.0))
		if age >= tracer:
			global_position = _hitscan_end
			_stop(true)
		return
	var at := launch_origin + flight.offset_at(launch_direction, age)
	if launch_origin.distance_to(at) >= flight.max_range or age >= flight.lifetime_ticks():
		_stop()
		return
	if flight.hits_world and _last.distance_squared_to(at) > 0.000001:
		_ray.from = _last
		_ray.to = at
		_ray.collision_mask = flight.world_mask
		var found := get_world_3d().direct_space_state.intersect_ray(_ray)
		if not found.is_empty():
			global_position = found["position"]
			_stop(true)
			return
	if stops_at_first_pawn and _touches_pawn(at):
		global_position = at
		_stop(true)
		return
	global_position = at
	_last = at
	var moving := flight.velocity_at(launch_direction, age)
	if moving.length_squared() > 0.0001:
		var forward := moving.normalized()
		basis = Basis.looking_at(forward, Vector3.UP if absf(forward.y) < 0.999 else Vector3.FORWARD)


# Hitscan: where its tracer ends on this machine: the world, or the first pawn on the line if it stops there.
func _trace_hitscan(origin: Vector3, direction: Vector3, from_pawn: Pawn) -> Vector3:
	var end := origin + direction * flight.max_range
	if flight.hits_world:
		var found := from_pawn.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin, end, flight.world_mask))
		if not found.is_empty():
			end = found["position"]
	if stops_at_first_pawn:
		var touched := HitQuery.touching(HitQuery.line_centres(origin, end, flight.radius), flight.radius, TickDriver.tick, from_pawn)
		if not touched.is_empty():
			end = HitQuery.point_on_path(origin, end, touched[0])
	return end


# It meets another pawn here: shown stopping, as the server's will.
func _touches_pawn(at: Vector3) -> bool:
	var sphere := SphereShape3D.new()
	sphere.radius = flight.radius
	_sphere_query.shape = sphere
	_sphere_query.collision_mask = 2 # pawns are on layer 2 (pawn.tscn)
	_sphere_query.exclude = [shooter.get_rid()] if is_instance_valid(shooter) else []
	_sphere_query.transform = Transform3D(Basis.IDENTITY, at)
	return not get_world_3d().direct_space_state.intersect_shape(_sphere_query, 1).is_empty()


# Stopped: hidden, with its impact shown if it met something.
func _stop(met_something := false) -> void:
	_stopped = true
	visible = false
	if met_something:
		flight.spawn_impact(get_parent(), global_position)
