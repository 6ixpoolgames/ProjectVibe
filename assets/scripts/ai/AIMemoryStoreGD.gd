## Written by Claude (claude-opus-5-5), 2026-11-09: one pawn's AI memory in GDScript, plus the loops that read and write it (the sight
## check, the most aware entry, target scoring). Pawn spec sections 10.4, 10.5 and 10.11.
##
## The same thing as AIMemoryStore in the navcore C++ library, with the same functions and the same rules, used where that library
## isn't available or AIMemory.use_native is off. The code moved here from AIMemory.gd and SightSense.gd when the C++ version was
## added. A change to one goes in the other, and ai_perception_selftest runs both and expects the same results.
##
## AIMemory owns one of these and keeps every setting; the fades, delays, sight settings and target weights are passed in.
class_name AIMemoryStoreGD
extends RefCounted

# One value per entry, all in the same order, kept as packed arrays rather than an object per entry.
var _ids := PackedInt64Array() # the entity's instance id
var _last_known := PackedVector3Array()
var _last_seen := PackedInt64Array()
var _last_checked := PackedInt64Array()
var _awareness_when_seen := PackedFloat32Array()
var _certain := PackedByteArray()
var _threat := PackedFloat32Array()
var _index_of := {} # instance id -> index, so find() doesn't search every entry

var _uncertain_fade: FadeProfile = null
var _uncertain_delay := 0
var _certain_fade: FadeProfile = null
var _certain_delay := 0
var _continuous_ticks := 30

# Sight settings, in the order set_sight_settings() takes them.
var _fill_rate := 1.0 / 30.0
var _near_range := 8.0
var _sight_range := 25.0
var _cos_central := 0.7071
var _cos_periphery := 0.1736
var _periphery_multiplier := 0.3
var _max_gain_ticks := 30
var _eye_height := 1.6
var _target_height := 1.0
var _blocking_mask := 1
var _sense_interval := 10
var _ray := PhysicsRayQueryParameters3D.new()


## The fades and their delays. custom isn't needed here: a profile's own value_at() is always called.
func configure_fades(uncertain: FadeProfile, uncertain_delay: int, _uncertain_custom: bool, certain: FadeProfile, certain_delay: int, _certain_custom: bool, continuous_sighting_ticks: int) -> void:
	_uncertain_fade = uncertain
	_uncertain_delay = uncertain_delay
	_certain_fade = certain
	_certain_delay = certain_delay
	_continuous_ticks = continuous_sighting_ticks


func entry_count() -> int:
	return _ids.size()


func find(entity: Object) -> int:
	if entity == null:
		return -1
	return _index_of.get(entity.get_instance_id(), -1)


func entity_at(index: int) -> Object:
	var id := _ids[index]
	# GDScript note: instance_from_id gives back the object for an id, but only if it still exists, which is_instance_id_valid checks.
	return instance_from_id(id) if is_instance_id_valid(id) else null


func awareness_at(index: int, tick: int) -> float:
	# GDScript note: value_at of a negative tick count is full, so the delay needs no special case.
	if _certain[index]:
		return _awareness_when_seen[index] * _certain_fade.value_at(tick - _last_seen[index] - _certain_delay)
	return _awareness_when_seen[index] * _uncertain_fade.value_at(tick - _last_seen[index] - _uncertain_delay)


func is_certain_at(index: int) -> bool:
	return _certain[index] != 0


func last_known_position_at(index: int) -> Vector3:
	return _last_known[index]


func ticks_since_seen_at(index: int, tick: int) -> int:
	return tick - _last_seen[index]


func threat_at(index: int) -> float:
	return _threat[index]


func ticks_since_checked(entity: Object, tick: int, fallback: int) -> int:
	var i := find(entity)
	return fallback if i < 0 else tick - _last_checked[i]


## Returns bits: 1 when a new entry was made, 2 when the entry became certain.
func record_sighting(entity: Object, gain: float, tick: int, position: Vector3) -> int:
	var result := 0
	var i := find(entity)
	if i < 0:
		_ids.append(entity.get_instance_id())
		_last_known.append(position)
		_last_seen.append(tick)
		_last_checked.append(tick)
		_awareness_when_seen.append(0.0)
		_certain.append(0)
		_threat.append(0.0)
		i = _ids.size() - 1
		_index_of[_ids[i]] = i
		result |= 1
	# Fading only counts while it isn't seen: sightings close together, with no unseen check between them, are one look.
	var in_view_all_along := _last_checked[i] == _last_seen[i] and tick - _last_seen[i] <= _continuous_ticks
	var before := _awareness_when_seen[i] if in_view_all_along else awareness_at(i, tick)
	var now := 1.0 if _certain[i] else minf(1.0, before + gain)
	_last_known[i] = position
	_last_seen[i] = tick
	_last_checked[i] = tick
	_awareness_when_seen[i] = now
	if now >= 1.0 and not _certain[i]:
		_certain[i] = 1
		result |= 2
	return result


func record_check(entity: Object, tick: int) -> void:
	var i := find(entity)
	if i >= 0:
		_last_checked[i] = tick


func add_threat(entity: Object, amount: float) -> void:
	var i := find(entity)
	if i >= 0:
		_threat[i] = maxf(0.0, _threat[i] + amount)


## Forgets entries whose fade has ended or whose entity is gone. Returns the ids of forgotten entities that still exist.
func forget_old(tick: int) -> PackedInt64Array:
	var forgotten := PackedInt64Array()
	var i := _ids.size() - 1
	while i >= 0: # backwards, so removing one doesn't move the ones still to check
		var lasts := _certain_delay + _certain_fade.ends_after() if _certain[i] else _uncertain_delay + _uncertain_fade.ends_after()
		var entity := entity_at(i)
		if entity == null or tick - _last_seen[i] >= lasts:
			if entity:
				forgotten.append(_ids[i])
			_remove(i)
		i -= 1
	return forgotten


## The entry with the highest awareness now, or -1. Ties go to the nearer last known position, then the lower id.
func most_aware_index(from: Vector3, tick: int) -> int:
	var best := -1
	var best_awareness := -1.0
	var best_distance := INF
	for i in _ids.size():
		var awareness := awareness_at(i, tick)
		var distance := from.distance_squared_to(_last_known[i])
		if awareness > best_awareness + 0.000001 \
				or (absf(awareness - best_awareness) <= 0.000001 and (distance < best_distance or (distance == best_distance and _ids[i] < _ids[best]))):
			best = i
			best_awareness = awareness
			best_distance = distance
	return best


func clear() -> void:
	for i in range(_ids.size() - 1, -1, -1):
		_remove(i)


## AITargetSelector's formula over every entry. Returns the winning index, or -1.
func best_target(from: Vector3, awareness_weight: float, distance_weight: float, threat_weight: float, distance_range: float, min_awareness: float, current_id: int, current_bonus: float, tick: int) -> int:
	var best := -1
	var best_priority := -INF
	var best_distance := INF
	var best_id := 0
	for i in _ids.size():
		var awareness := awareness_at(i, tick)
		if awareness < min_awareness or entity_at(i) == null:
			continue
		var distance := from.distance_to(_last_known[i])
		var priority := awareness_weight * awareness + distance_weight * (1.0 - clampf(distance / distance_range, 0.0, 1.0)) + threat_weight * _threat[i]
		if current_id != 0 and _ids[i] == current_id:
			priority += current_bonus
		var distance_squared := distance * distance
		if priority > best_priority + 0.000001 \
				or (absf(priority - best_priority) <= 0.000001 and (distance_squared < best_distance or (distance_squared == best_distance and _ids[i] < best_id))):
			best = i
			best_priority = priority
			best_distance = distance_squared
			best_id = _ids[i]
	return best


## SightSense's settings: fill_rate, near_range, sight_range, cos of half the central cone, cos of half the periphery,
## periphery_multiplier, max_gain_ticks, eye_height, target_height, sight_blocking_mask, sense_interval_ticks.
func set_sight_settings(settings: PackedFloat64Array) -> void:
	if settings.size() < 11:
		return
	_fill_rate = settings[0]
	_near_range = settings[1]
	_sight_range = settings[2]
	_cos_central = settings[3]
	_cos_periphery = settings[4]
	_periphery_multiplier = settings[5]
	_max_gain_ticks = int(settings[6])
	_eye_height = settings[7]
	_target_height = settings[8]
	_blocking_mask = int(settings[9])
	_sense_interval = int(settings[10])


## Checks each candidate from observer's eyes, facing eye_yaw, and records what's seen. Returns [a new entry was made, entities that
## became certain]. See SightSense for the rules.
func sight_check(observer: Node3D, eye_yaw: float, candidates: Array, tick: int) -> Array:
	var became_certain := []
	var added := false
	if observer == null or not observer.is_inside_tree():
		return [false, became_certain]
	var eye := observer.global_position + Vector3(0.0, _eye_height, 0.0)
	var facing := Vector2(-sin(eye_yaw), -cos(eye_yaw)) # Godot's forward is -Z, so yaw 0 faces -Z
	var space: PhysicsDirectSpaceState3D = null
	for candidate in candidates:
		var target := candidate as Node3D
		if target == null or target == observer or not target.is_inside_tree():
			continue
		var ticks := clampi(ticks_since_checked(target, tick, _sense_interval), 0, _max_gain_ticks)
		var target_position := target.global_position
		var aim := target_position + Vector3(0.0, _target_height, 0.0)
		var visibility := _visibility(eye, facing, aim, target)
		var seen := false
		# The ray is the expensive part, so it's only cast when the target could be seen at all.
		if visibility > 0.0 and ticks > 0:
			if space == null:
				space = observer.get_world_3d().direct_space_state
			seen = _clear_line(space, observer, target, eye, aim)
		if seen:
			var bits := record_sighting(target, _fill_rate * ticks * visibility, tick, target_position)
			added = added or bits & 1 != 0
			if bits & 2:
				became_certain.append(target)
		else:
			record_check(target, tick)
	return [added, became_certain]


# --- Internals ---


func _visibility(eye: Vector3, facing: Vector2, aim: Vector3, target: Node3D) -> float:
	var distance := eye.distance_to(aim)
	if distance > _sight_range:
		return 0.0
	var distance_factor := 1.0
	if distance > _near_range:
		distance_factor = 1.0 - (distance - _near_range) / maxf(_sight_range - _near_range, 0.001)
	var flat := Vector2(aim.x - eye.x, aim.z - eye.z)
	var angle_factor := 1.0
	if flat.length_squared() > 0.0001:
		var cosine := facing.dot(flat.normalized()) # a bigger cosine means a smaller angle
		if cosine < _cos_periphery:
			return 0.0
		if cosine < _cos_central:
			angle_factor = _periphery_multiplier
	var detectability: Variant = target.get(&"detectability")
	return distance_factor * angle_factor * (float(detectability) if detectability != null else 1.0)


func _clear_line(space: PhysicsDirectSpaceState3D, observer: Node3D, target: Node3D, from: Vector3, to: Vector3) -> bool:
	_ray.from = from
	_ray.to = to
	_ray.collision_mask = _blocking_mask
	var observer_body := observer as CollisionObject3D
	var target_body := target as CollisionObject3D
	var layers := (observer_body.collision_layer if observer_body else 0) | (target_body.collision_layer if target_body else 0)
	# Only when pawns can block sight: then the ray mustn't stop at either end's own body. Skipping it otherwise saves an array.
	if _blocking_mask & layers:
		_ray.exclude = [observer_body.get_rid(), target_body.get_rid()]
	elif not _ray.exclude.is_empty():
		_ray.exclude = []
	return space.intersect_ray(_ray).is_empty()


func _remove(i: int) -> void:
	_index_of.erase(_ids[i])
	for later in range(i + 1, _ids.size()):
		_index_of[_ids[later]] = later - 1 # every entry after this one moves down a place
	_ids.remove_at(i)
	_last_known.remove_at(i)
	_last_seen.remove_at(i)
	_last_checked.remove_at(i)
	_awareness_when_seen.remove_at(i)
	_certain.remove_at(i)
	_threat.remove_at(i)
