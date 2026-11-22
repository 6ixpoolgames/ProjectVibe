# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## An attack's hit window: a hit sphere moves along a path over length_ticks, and pawns it touches are hit.
##
## Each point on the path is an angle (degrees, positive to the left, 0 straight ahead), a height (metres above the feet) and a reach
## (metres to the sphere's far edge), measured from its [member anchor]: the pawn as it moves and turns (a swing), or where the pawn
## stood when the step began (a cleave left in the world). The path goes from start to end, or through its [member keys] (ability spec
## 7), so an arc can curve, dip or reach out mid-swing; a weapon's path baked from its animation is a set of keys. Visuals draw the
## same path ([method offset_at]).
## [br][br]Hits are decided on the server only (or offline), never in a rollback replay. Each pawn is hit at most once per run of the
## ability, and who it may hit and what a hit does come from its [HitDefinition] (its own [member hit], else its ability's), through the
## same hit system as a projectile's (ability spec 13). Signals go out on the ability.
## Design: pawn spec 8.20.
class_name MeleeSweepStep
extends AbilityStep

## What the path is measured from.
enum Anchor {
	PAWN, ## the pawn, as it moves and turns: a swing
	WORLD, ## where the pawn stood and faced when the step began: a cleave or slam left in the world
}

## What the path is measured from.
@export var anchor := Anchor.PAWN
## Points the path goes through, in order of their time (ability spec 7). Fewer than two: from Start to End below.
@export var keys: Array[SweepKey] = []

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
## Who this sweep may hit and what it does, in place of its ability's (a backswing that pushes harder). Empty: the ability's.
@export var hit: HitDefinition

## With a WORLD anchor: where the pawn stood and faced as the step began. Rolls back.
var anchor_origin := Vector3.ZERO
var anchor_yaw := 0.0
var _sorted_keys: Array[SweepKey] = [] # keys in order of time, sorted when keys changes
var _sorted_from: Array[SweepKey] = []


func _init() -> void:
	super()
	length_ticks = 4


## Where the hit sphere's centre is at this point of the sweep (0 start, 1 end), from the anchor's feet, for a facing in radians.
func offset_at(at: float, facing: float) -> Vector3:
	# The parameter is "at" because "progress" is a method every step has.
	var point := path_point(at)
	var angle := facing + deg_to_rad(point.x)
	var forward := Vector3(-sin(angle), 0.0, -cos(angle)) # Godot's forward is -Z; a bigger yaw turns left
	return forward * maxf(point.z - hit_radius, 0.0) + Vector3(0.0, point.y, 0.0)


## The path at this point of the sweep: (angle in degrees, height, reach), from its keys, or from Start to End.
func path_point(at: float) -> Vector3:
	if keys.size() < 2:
		return Vector3(start_angle, start_height, start_reach).lerp(Vector3(end_angle, end_height, end_reach), at)
	if _sorted_from != keys:
		_sorted_from = keys.duplicate()
		_sorted_keys = keys.filter(func(key: SweepKey) -> bool: return key != null)
		_sorted_keys.sort_custom(func(a: SweepKey, b: SweepKey) -> bool: return a.at < b.at)
	var first := _sorted_keys[0]
	if at <= first.at:
		return Vector3(first.angle, first.height, first.reach)
	for i in range(1, _sorted_keys.size()):
		var later := _sorted_keys[i]
		if at <= later.at:
			var earlier := _sorted_keys[i - 1]
			var weight := (at - earlier.at) / maxf(later.at - earlier.at, 0.0001)
			return Vector3(earlier.angle, earlier.height, earlier.reach).lerp(Vector3(later.angle, later.height, later.reach), weight)
	var last := _sorted_keys[_sorted_keys.size() - 1]
	return Vector3(last.angle, last.height, last.reach)


## The point the path is measured from now: the pawn's feet, or where it stood as the step began.
func anchor_point() -> Vector3:
	return anchor_origin if anchor == Anchor.WORLD else pawn.global_position


## The facing the path is measured from now, in radians.
func anchor_facing() -> float:
	return anchor_yaw if anchor == Anchor.WORLD else pawn.yaw


func enter() -> void:
	if anchor == Anchor.WORLD:
		anchor_origin = pawn.global_position
		anchor_yaw = pawn.yaw


func get_rollback_properties() -> Array[String]:
	if anchor == Anchor.WORLD:
		return ["anchor_origin", "anchor_yaw"] # where it was left, for a rollback mid-sweep
	return []


## The spots the sphere passes through on this sweep tick (0 is the first), in the world, no more than half its radius apart. One spot
## if it doesn't move, so a fast sweep or a 30 Hz match leaves no gaps.
func centres_for_tick(sweep_tick: int) -> Array[Vector3]:
	return centres_for_ticks(sweep_tick, 1)


## The same over count ticks from sweep_tick, for a pawn running every Nth tick (pawn spec 8.21). Never goes past the sweep's end.
func centres_for_ticks(sweep_tick: int, count: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var ticks := float(maxi(length(), 1))
	var from_progress := minf(sweep_tick / ticks, 1.0)
	var to_progress := minf((sweep_tick + maxi(count, 1)) / ticks, 1.0)
	var facing := anchor_facing()
	var origin := anchor_point()
	var from_spot := offset_at(from_progress, facing)
	var to_spot := offset_at(to_progress, facing)
	# The straight distance this tick: close to the arc for one tick's part of a sweep, and counts reach or height changes too.
	var moved := from_spot.distance_to(to_spot)
	if moved < 0.0001:
		out.append(origin + offset_at((from_progress + to_progress) * 0.5, facing))
		return out
	var spots := maxi(1, ceili(moved / maxf(hit_radius * 0.5, 0.01)))
	for i in spots + 1:
		out.append(origin + offset_at(lerpf(from_progress, to_progress, float(i) / spots), facing))
	return out


func tick(_dt: float) -> Status:
	# In a replay nothing below happens (no signals, no hits), so leave before working out the spots.
	if TickDriver.is_resimulating():
		return Status.RUNNING
	var centres := centres_for_ticks(step_ticks, ability.ticks_elapsed()) # every tick this run covers (pawn spec 8.21)
	if step_ticks == 0:
		ability.hit_window_started.emit(centres[0], hit_radius)
	ability.hit_area_moved.emit(centres[0], centres[centres.size() - 1], hit_radius)
	if pawn.is_authority(): # hits are decided once, on the server
		_check_hits(TickDriver.tick, centres)
	return Status.RUNNING # done after length_ticks


func weapon_point(facing: float) -> Variant:
	if anchor == Anchor.WORLD:
		# Left in the world: where it is, from the pawn's feet now, whichever way the pawn faces.
		return anchor_point() + offset_at(progress(), anchor_facing()) - pawn.global_position
	return offset_at(progress(), facing)


# The sweep's spheres this tick through the shared hit system (ability spec 13.1): who they touch (HitQuery, as the attacker saw them in
# a session), then the ability's hit run: met once, checked against the hit definition, hit through land_hit.
func _check_hits(on_tick: int, centres: Array[Vector3]) -> void:
	var started := PerfScopes.begin() # timed for diagnostics: a swing's whole hit check
	_check_hits_timed(on_tick, centres)
	PerfScopes.end(&"melee.hits", started)


func _check_hits_timed(on_tick: int, centres: Array[Vector3]) -> void:
	var run := ability.get_hit_run()
	run.hit = hit.resolved() as HitDefinition if hit else ability.hit_definition() # variants applied, as the ability's is
	if run.is_spent():
		return # its max_hits or max_intersects is reached: this run hits no one else
	var spots := PackedVector3Array(centres)
	var touched := HitQuery.touching(spots, hit_radius, on_tick, pawn, ability.view_ticks_behind(), run.hit.hits_self)
	run.meet_pawns(touched, on_tick, pawn, spots[0], spots[spots.size() - 1], spots[spots.size() - 1] - spots[0], anchor_point())
