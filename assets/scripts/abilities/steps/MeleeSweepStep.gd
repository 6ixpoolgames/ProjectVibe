## Written by Claude (claude-opus-5-5), 2026-11-16 (pawn spec 8.20, the owner's design): an attack's hit window. A hit sphere moves from
## a start point to an end point over length_ticks, and pawns it touches are hit. Moved here from MeleeAttackAbility, which used to do
## this itself in its hit phase; the rules are the same.
##
## Each point is around the pawn, relative to where it faces at each tick:
##   angle    degrees, positive to the pawn's left, 0 straight ahead
##   height   metres above the pawn's feet
##   reach    metres from the pawn to the far edge of the hit sphere
## Each goes straight from start to end, so a slash changes angle, a thrust changes reach, a chop changes height, and a diagonal cut
## changes two. Longer patterns (a zig-zag, a spin) are several sweeps in a row. Visuals draw exactly this path (offset_at), so a new
## pattern needs no visual work.
##
## Hits, on the server only (or offline), never in a rollback replay:
##   - Each tick checks every spot the sphere passes through during that tick, no more than half its radius apart, so a fast sweep or a
##     30 Hz match leaves no gaps; in a session they're checked through lag compensation (LagCompensation.melee_spheres), against
##     where the player saw others.
##   - Each pawn is hit at most once per run of the ability, across all its sweeps (AbilityBase.pawns_hit_this_run). Its own team is
##     skipped unless hits_own_team is on; an invulnerable pawn isn't hit or marked, so a later tick can catch it.
##   - A hit carries the ability's on-hit effects (its EffectApplier children) and goes to the target's AbilityManager.receive_hit().
## Signals go out on the ability, if it has them (MeleeAttackAbility does): hit_window_started on the first tick, hit_area_moved on
## every tick (both on every machine running it, outside replays), and hit_landed for each hit (on the server).
class_name MeleeSweepStep
extends AbilityStep

@export_group("Start")
## Degrees from straight ahead, positive to the pawn's left.
@export_range(-360.0, 360.0, 1.0) var start_angle := -50.0
## Metres above the pawn's feet.
@export var start_height := 1.0
## Metres from the pawn to the far edge of the hit sphere.
@export_range(0.1, 20.0, 0.05, "or_greater") var start_reach := 1.8

@export_group("End")
@export_range(-360.0, 360.0, 1.0) var end_angle := 50.0
@export var end_height := 1.0
@export_range(0.1, 20.0, 0.05, "or_greater") var end_reach := 1.8

@export_group("")
## The hit sphere's radius, in metres.
@export_range(0.05, 10.0, 0.05, "or_greater") var hit_radius := 0.8
## On: it can hit pawns on its own team.
@export var hits_own_team := false

var _warned_no_effects := false


func _init() -> void:
	super()
	length_ticks = 4


## Where the hit sphere's centre is at this point of the sweep (0 its start, 1 its end), from the pawn's feet, for a facing in radians.
func offset_at(at: float, facing: float) -> Vector3:
	# GDScript note: the parameter is "at", not "progress", which is a function every step has (AbilityStep.progress()).
	var angle := facing + deg_to_rad(lerpf(start_angle, end_angle, at))
	var forward := Vector3(-sin(angle), 0.0, -cos(angle)) # Godot's forward is -Z; a bigger yaw turns left
	var reach := lerpf(start_reach, end_reach, at)
	return forward * maxf(reach - hit_radius, 0.0) + Vector3(0.0, lerpf(start_height, end_height, at), 0.0)


## The spots the sphere passes through on this tick of the sweep (0 for the first), in the world: from where it is at the tick's start
## to where it is at its end, no more than half its radius apart. One spot if it doesn't move.
func centres_for_tick(sweep_tick: int) -> Array[Vector3]:
	return centres_for_ticks(sweep_tick, 1)


## Claude 2026-11-16 (pawn spec 8.21): the same over count ticks from sweep_tick, for a pawn that runs every Nth tick and sweeps N ticks'
## worth at once. It never goes past the sweep's end.
func centres_for_ticks(sweep_tick: int, count: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var ticks := float(maxi(length(), 1))
	var from_progress := minf(sweep_tick / ticks, 1.0)
	var to_progress := minf((sweep_tick + maxi(count, 1)) / ticks, 1.0)
	var from_spot := offset_at(from_progress, pawn.yaw)
	var to_spot := offset_at(to_progress, pawn.yaw)
	# The straight distance between where it starts and ends this tick: close to the arc for one tick's part of a sweep, and it counts
	# a change of reach or height too.
	var moved := from_spot.distance_to(to_spot)
	if moved < 0.0001:
		out.append(pawn.global_position + offset_at((from_progress + to_progress) * 0.5, pawn.yaw))
		return out
	var spots := maxi(1, ceili(moved / maxf(hit_radius * 0.5, 0.01)))
	for i in spots + 1:
		out.append(pawn.global_position + offset_at(lerpf(from_progress, to_progress, float(i) / spots), pawn.yaw))
	return out


func tick(_dt: float) -> Status:
	# Claude 2026-11-16 (wider audit): in a rollback replay nothing below happens (no signals, no hits), so it leaves before working
	# out the spots; and the TickDriver autoload is used directly, where it was looked up by path every hit tick.
	if TickDriver.is_resimulating():
		return Status.RUNNING
	var centres := centres_for_ticks(step_ticks, ability.ticks_elapsed()) # Claude 2026-11-16 (pawn spec 8.21): every tick this run covers
	if step_ticks == 0 and ability.has_signal(&"hit_window_started"):
		ability.emit_signal(&"hit_window_started", centres[0], hit_radius)
	if ability.has_signal(&"hit_area_moved"):
		ability.emit_signal(&"hit_area_moved", centres[0], centres[centres.size() - 1], hit_radius)
	if pawn.is_authority(): # hits are decided once, on the server
		_check_hits(TickDriver.tick, centres)
	return Status.RUNNING # done after length_ticks


func weapon_point(facing: float) -> Variant:
	return offset_at(progress(), facing)


func _check_hits(on_tick: int, centres: Array[Vector3]) -> void:
	var targets: Array[Pawn] = []
	var entity := pawn.get_network_entity()
	# Through lag compensation in a network session; offline there's nobody to rewind, and pawns aren't tagged for it.
	# Claude 2026-11-17 (C++ bundle stage 3): when nothing would be rewound (every AI swing, and offline play), the pawn grid finds who
	# the spheres touch in C++ (AIPawnGrid.find_touching), instead of a physics query per spot. Same answer: the exact shapes, where
	# they are now. Without the C++ library, physics as before.
	var view_behind := ability.view_ticks_behind()
	if entity and entity.session and LagCompensation.would_rewind(entity, view_behind):
		for found in LagCompensation.melee_spheres(entity, centres, hit_radius, view_behind):
			var other := found.get_parent() as Pawn
			if other:
				targets.append(other)
	elif Pawn.get_grid() != null and pawn.is_inside_tree():
		for found: Object in Pawn.get_grid().find_touching(PackedVector3Array(centres), hit_radius, pawn, on_tick):
			if found is Pawn:
				targets.append(found)
	else:
		targets = _plain_spheres(centres)
	for target in targets:
		if target == pawn or target.is_dead() or ability.pawns_hit_this_run.has(target.get_instance_id()):
			continue
		# A dashing pawn isn't hit, and isn't marked as hit either, so the rest of the sweep can catch it once its dash ends.
		if target.ability_manager and target.ability_manager.is_invulnerable():
			continue
		if target.team == pawn.team and not hits_own_team:
			continue
		ability.pawns_hit_this_run.append(target.get_instance_id())
		var hit := HitInfo.new()
		hit.attacker = pawn
		hit.target = target
		hit.ability = ability
		hit.tick = on_tick
		var away := target.global_position - pawn.global_position
		away.y = 0.0
		hit.direction = away.normalized() if away.length_squared() > 0.0001 else Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw))
		hit.effects = ability.on_hit_effects
		hit.attacker_effects = ability.on_hit_self_effects
		if ability.on_hit_effects.is_empty() and ability.on_hit_self_effects.is_empty() and not _warned_no_effects:
			_warned_no_effects = true
			push_warning("%s hit %s but has no on-hit effects (EffectApplier children), so the hit does nothing." % [ability.name, target.name])
		if target.ability_manager: # a pawn with no abilities can't be hit
			target.ability_manager.receive_hit(hit)
		if ability.has_signal(&"hit_landed"):
			ability.emit_signal(&"hit_landed", hit)


var _query: PhysicsShapeQueryParameters3D = null # Claude 2026-11-16 (wider audit): kept between hit ticks (_plain_spheres)

# Offline, or for a pawn without a NetworkEntity: the same spheres, with no rewinding.
func _plain_spheres(centres: Array[Vector3]) -> Array[Pawn]:
	var found: Array[Pawn] = []
	# Claude 2026-11-16 (wider audit): the sphere and the query are made once and kept; a new pair was made on every hit tick.
	if _query == null:
		_query = PhysicsShapeQueryParameters3D.new()
		_query.shape = SphereShape3D.new()
		_query.exclude = [pawn.get_rid()]
	(_query.shape as SphereShape3D).radius = hit_radius
	var query := _query
	var space := pawn.get_world_3d().direct_space_state
	for centre in centres:
		query.transform = Transform3D(Basis.IDENTITY, centre)
		for hit in space.intersect_shape(query):
			var other := hit.collider as Pawn
			if other and not found.has(other):
				found.append(other)
	return found
