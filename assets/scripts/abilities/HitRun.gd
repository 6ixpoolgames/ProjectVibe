# Written by Claude (claude-opus-5-5), 2026-11-22. History: abilities/CHANGELOG.md.
## What one hit volume has done: whom it hit, everything it met, and whether it's spent (ability spec 13.3). Shared by swings and projectiles.
##
## A swing's run belongs to the run of its ability; a projectile owns one, so two bolts of a volley can each hit the same pawn. Each
## tick the volume hands it the pawns [HitQuery] found (and the world, if it met it): each pawn is met once, logged, checked against the
## [HitDefinition], and hit through [method AbilityBase.land_hit]. The hit list lives on its holder (an ability's rolled-back
## [member AbilityBase.pawns_hit_this_run], or a projectile's own), so a rollback restores it. The intersect log is packed arrays, for
## hooks and debugging, not rolled back.
class_name HitRun
extends RefCounted

## What it meets.
enum Kind { PAWN, WORLD }
## How high a pawn's body is checked for the world check, in metres above its feet.
const BODY_HEIGHT := 1.8

## Who and what a hit does. Set by its owner, and swappable between ticks.
var hit: HitDefinition = null
## The ability whose hits these are; land_hit goes through it. Null once it's gone: then pawns are met but not hit.
var ability: AbilityBase = null
## The attacker's team, for the whitelist (kept, so a shooter that's gone still has one).
var team := 0
## Called with each log entry as it's made (a Dictionary, see [method entry]); the owner sends its own hook from it.
var on_intersect: Callable

# The hit list's holder and property: a PackedInt64Array of pawn keys (HitInfo.key_of).
var _holder: Object = null
var _list: StringName = &""
# The intersect log, one entry per thing met, in order.
var _keys := PackedInt64Array()
var _ticks := PackedInt64Array()
var _points := PackedVector3Array()
var _normals := PackedVector3Array()
var _flags := PackedByteArray() # bit 0: hit; bit 1: the world; bit 2: blocked by the world
var _targets: Array[Pawn] = []
var _hits := 0
# What a hit needs if its source goes (lands_without_source): the effects it had and its attacker's key, kept by remember_source.
var _kept_effects: Array[Effect] = []
var _attacker_key := -1
## Where the meeting that spent it was.
var last_point := Vector3.ZERO


## A run whose hit list is this property of holder (its owner keeps the list, and rolls it back if it should).
func _init(list_holder: Object = null, list_property: StringName = &"") -> void:
	_holder = list_holder
	_list = list_property


## Keeps what a hit needs if its source goes before it lands (the hit definition's lands_without_source): the ability's on-hit effects
## and the hit definition's, and the attacker's id. A projectile calls it as it sets off.
func remember_source(source: AbilityBase) -> void:
	_kept_effects.clear()
	if source:
		_kept_effects.append_array(source.on_hit_effects)
		_attacker_key = HitInfo.key_of(source.pawn) if source.pawn else -1
	if hit:
		for effect in hit.target_effects:
			if effect:
				effect.register()
				_kept_effects.append(effect)


## Starts again: no one met, nothing hit. A swing's run calls it when its ability starts; the hit list is cleared by its holder.
func clear() -> void:
	_keys.clear()
	_ticks.clear()
	_points.clear()
	_normals.clear()
	_flags.clear()
	_targets.clear()
	_hits = 0


## Handles the pawns a volume touched this tick, nearest first: each one met for the first time is logged and, if the hit definition
## allows, hit (path_start and path_end place meetings, motion gives the push, reach_from is where the world check starts; null:
## path_start). True once it's spent (max_hits or max_intersects): the caller stops there.
func meet_pawns(pawns: Array[Pawn], tick: int, attacker: Pawn, path_start: Vector3, path_end: Vector3, motion: Vector3,
		reach_from: Variant = null) -> bool:
	for target in pawns:
		if target.is_dead():
			continue
		# An invulnerable pawn isn't met or marked, so a later tick can catch it once that ends (a dash's).
		if target.ability_manager and target.ability_manager.is_invulnerable():
			continue
		var key := HitInfo.key_of(target)
		if _keys.has(key) or _listed(key):
			continue
		var at := HitQuery.point_on_path(path_start, path_end, target)
		var has_source := is_instance_valid(ability)
		var blocked := hit != null and hit.blocked_by_world and _world_between(reach_from if reach_from != null else path_start, at, target)
		var allowed := hit != null and not blocked and hit.allows(attacker, target, team) and (has_source or hit.lands_without_source) and _note(key)
		_log(key, tick, at, Vector3.ZERO, (1 if allowed else 0) | (4 if blocked else 0), target)
		if allowed:
			_hits += 1
			var origin := attacker.global_position if is_instance_valid(attacker) else path_start
			var push := hit.push_direction(origin, target.global_position, motion)
			if has_source:
				ability.land_hit(target, push, tick, at, hit)
			else:
				_land_without_source(target, push, tick)
		if is_spent():
			last_point = at
			return true
	return false


# Its source is gone and its hit definition lands anyway: the same HitInfo, with the effects it had and credit to the attacker's id.
func _land_without_source(target: Pawn, push: Vector3, tick: int) -> void:
	var hit_info := HitInfo.make(null, null, target, push, tick, _kept_effects, [])
	hit_info.attacker_id = _attacker_key
	hit_info.deliver()


# True if the world's in the way along the weapon's reach: from reach_from's axis at the height the hit met the target, out to that
# point, then on to the target's body at that height.
func _world_between(reach_from: Vector3, at: Vector3, target: Pawn) -> bool:
	if not target.is_inside_tree():
		return false
	var started := PerfScopes.begin() # timed for diagnostics: the world check's two rays
	var blocked := _world_between_timed(reach_from, at, target)
	PerfScopes.end(&"hits.world_check", started)
	return blocked


func _world_between_timed(reach_from: Vector3, at: Vector3, target: Pawn) -> bool:
	var space := target.get_world_3d().direct_space_state
	var root := Vector3(reach_from.x, at.y, reach_from.z)
	var feet := target.global_position.y
	var body := Vector3(target.global_position.x, clampf(at.y, feet, feet + BODY_HEIGHT), target.global_position.z)
	for leg: Array in [[root, at], [at, body]]:
		if (leg[0] as Vector3).distance_squared_to(leg[1]) < 0.000001:
			continue
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(leg[0], leg[1], hit.world_mask)).is_empty():
			return true
	return false


## Logs meeting the world here. Returns true if that spends it (max_intersects).
func meet_world(tick: int, at: Vector3, normal: Vector3) -> bool:
	_log(-1, tick, at, normal, 2 | 1, null)
	return is_spent()


## True once it has hit max_hits pawns, or met max_intersects things.
func is_spent() -> bool:
	if hit == null:
		return false
	return (hit.max_hits > 0 and _hits >= hit.max_hits) or (hit.max_intersects > 0 and _keys.size() >= hit.max_intersects)


## How many pawns it has hit.
func hit_count() -> int:
	return _hits


## How many things it has met.
func intersect_count() -> int:
	return _keys.size()


## One log entry: {"tick", "kind" (Kind), "target" (a Pawn or null), "key" (its id), "point", "normal" (the world's), "hit", "blocked"
## (the world was in the way)}.
func entry(index: int) -> Dictionary:
	var world := _flags[index] & 2 != 0
	return {"tick": _ticks[index], "kind": Kind.WORLD if world else Kind.PAWN, "target": _targets[index], "key": _keys[index],
		"point": _points[index], "normal": _normals[index], "hit": _flags[index] & 1 != 0, "blocked": _flags[index] & 4 != 0}


func _log(key: int, tick: int, at: Vector3, normal: Vector3, flags: int, target: Pawn) -> void:
	_keys.append(key)
	_ticks.append(tick)
	_points.append(at)
	_normals.append(normal)
	_flags.append(flags)
	_targets.append(target)
	if on_intersect.is_valid():
		on_intersect.call(entry(_keys.size() - 1))


# Whether the holder's hit list already has this pawn.
func _listed(key: int) -> bool:
	if _holder == null:
		return false
	var list: PackedInt64Array = _holder.get(_list)
	return list.has(key)


# Puts the pawn in the holder's hit list; false if the holder refuses (an ability's run at its cap).
func _note(key: int) -> bool:
	if _holder == null:
		return true
	if _holder is AbilityBase:
		return (_holder as AbilityBase).note_hit_key(key)
	var list: PackedInt64Array = _holder.get(_list)
	list.append(key)
	_holder.set(_list, list)
	return true
