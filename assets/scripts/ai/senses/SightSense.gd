# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Sight, for basic stealth: fills awareness of other-team pawns it can see, faster when they're close and in front.
##
## A child of the pawn's [AISensingManager]. For each other-team pawn it checks, on a full pass or a refresh:
## [codeblock]
## if there's no line of sight: no gain
## gain = fill_rate × ticks_since_last_check × distance_factor × angle_factor × the target's detectability (its stat)
## [/codeblock]
## Ticks since the last check (capped at [member max_gain_ticks]) make the checking rate not matter; the distance factor is 1 inside
## [member near_range] and falls to 0 at [member sight_range]; the angle factor is 1 in the central cone, [member periphery_multiplier]
## in the periphery, 0 outside. Line of sight is one ray from the eyes to the target, blocked only by [member sight_blocking_mask]. The
## eyes face where the AI is looking, else the way the body faces (where the player looks while one has the pawn). The checks run in the
## pawn's memory store ([code]AIMemoryStore[/code] in C++, else [AIMemoryStoreGD]); with C++ the ray is tested against
## [SightGeometryFeeder]'s geometry, on worker threads when the sensing job runs. Refreshes check only the current target.
## Design: pawn spec 10.4, scaling spec step 4.
# REFACTOR: visibility_of() and has_line_of_sight() are a third copy of the sight rule (beside AIMemoryStoreGD and C++'s
# ai_sight_rules.h). Asking the pawn's memory store would leave one GDScript copy to keep in step (reusable). See CHANGELOG.md.
class_name SightSense
extends AISenseBase

## Awareness a fully visible target adds per tick: 1/30 fills it in 30 ticks, half a second. Per tick at 60 a second; at another rate
## it's converted to fill at the same speed.
@export_range(0.0, 1.0, 0.001, "or_greater") var fill_rate := 1.0 / 30.0:
	set(value):
		fill_rate = value
		_settings_dirty = true
## Inside this distance, in metres, distance doesn't weaken sight at all.
@export_range(0.0, 200.0, 0.5, "or_greater") var near_range := 8.0:
	set(value):
		near_range = value
		_settings_dirty = true
## Beyond this distance, in metres, nothing is seen.
@export_range(0.0, 500.0, 0.5, "or_greater") var sight_range := 25.0:
	set(value):
		sight_range = value
		_settings_dirty = true
## The width of the central cone, in degrees, where sight is at full strength.
@export_range(0.0, 360.0, 1.0) var central_cone_degrees := 90.0:
	set(value):
		central_cone_degrees = value
		_settings_dirty = true
## The width of everything it can see, in degrees, the central cone included. The part outside the central cone is the periphery.
@export_range(0.0, 360.0, 1.0) var periphery_degrees := 160.0:
	set(value):
		periphery_degrees = value
		_settings_dirty = true
## How strongly the periphery sees, compared with the central cone.
@export_range(0.0, 1.0, 0.01) var periphery_multiplier := 0.3:
	set(value):
		periphery_multiplier = value
		_settings_dirty = true
## The most ticks one check can count, so a long gap doesn't give a huge gain at once.
@export_range(1, 600, 1, "or_greater") var max_gain_ticks := 30:
	set(value):
		max_gain_ticks = value
		_settings_dirty = true
## The height of the eyes above the pawn's feet, in metres.
@export var eye_height := 1.6:
	set(value):
		eye_height = value
		_settings_dirty = true
## The height on the target the ray aims at, in metres above its feet: about the chest.
@export var target_height := 1.0:
	set(value):
		target_height = value
		_settings_dirty = true
## Physics layers that block sight. The world, layer 1, by default.
@export_flags_3d_physics var sight_blocking_mask := 1:
	set(value):
		sight_blocking_mask = value
		_settings_dirty = true

# Reused for every ray, so checks create no new objects.
var _ray := PhysicsRayQueryParameters3D.new()
# The settings handed to memory's store and the sensing job, in the order AIMemoryStore.set_sight_settings takes them. Filled again
# only when a setting or the match's tick rate changes, and sent to the store only then.
var _settings := PackedFloat64Array()
var _settings_dirty := true
var _settings_rate := -1 # the tick rate they were filled at
var _store_given: Object = null # the store that has these settings and the geometry below
var _geometry_given: Object = null
var _one_target: Array = [null] # reused for a refresh's single check


## Its [member sight_range].
func get_range() -> float:
	return sight_range


## The whole pass runs in memory's store (C++ when available, else GDScript), with this sense's settings.
func full_pass(candidates: Array[Pawn], tick: int) -> void:
	_check_all(candidates, tick)


## The full pass with the sensing job's result: the job found the candidates, how visible each is and (against SightGeometry) the
## line of sight, on a worker thread; this records them, the same as full_pass would. AISensingManager calls it.
func full_pass_prepared(job: Object, tick: int) -> void:
	var memory := pawn.ai_context.memory if pawn and pawn.ai_context else null
	if memory == null:
		return
	var store: Object = memory.get_store()
	_give_store(store) # the settings ask_job used a tick ago, for this same pass
	memory.announce_sight_results(store.sight_check_prepared(job, pawn, tick))


## Asks the sensing job for next tick's full pass, with where the eyes face now and this sense's settings.
func ask_job(job: Object, reach: float, max_candidates: int) -> void:
	job.add_request(pawn, _eye_yaw(), reach, max_candidates, _settings_now())


## Only the current target, one ray. Refreshing every remembered entity costs more than the full passes in a crowd (measured with
## ai_stress), and keeping a tracked target fresh is what the refresh is for.
func refresh(tick: int) -> void:
	var context := pawn.ai_context if pawn else null
	# has_target() first. The target can be freed between AI steps (a spawner removing a body), and casting a freed object is a
	# script error.
	var target := context.current_target as Pawn if context and context.has_target() else null
	if target and target.is_inside_tree():
		_one_target[0] = target
		_check_all(_one_target, tick)


## How strongly this pawn would see the target now, before line of sight and the time factor: distance × angle × detectability.
## 0 when it's out of range or outside the periphery. Public so tests and debug readouts can show it.
func visibility_of(target: Pawn) -> float:
	_begin_checks()
	return _visibility(target)


## True if nothing in sight_blocking_mask is between the eyes and the target.
func has_line_of_sight(target: Pawn) -> bool:
	var space := pawn.get_world_3d().direct_space_state
	_ray.from = pawn.global_position + Vector3(0.0, eye_height, 0.0)
	_ray.to = target.global_position + Vector3(0.0, target_height, 0.0)
	_ray.collision_mask = sight_blocking_mask
	# Only when pawns can block sight: then the ray mustn't stop at either end's own body. With the default mask it can't, and
	# skipping this saves making a new array for every ray.
	if sight_blocking_mask & (pawn.collision_layer | target.collision_layer):
		_ray.exclude = [pawn.get_rid(), target.get_rid()]
	elif not _ray.exclude.is_empty():
		_ray.exclude = []
	return space.intersect_ray(_ray).is_empty()


# --- Internals ---


# Worked out once per pass rather than once per target: where the eyes are, which way they face, and the cone edges as cosines, so
# angle checks are a dot product.
var _eye := Vector3.ZERO
var _facing := Vector2.ZERO
var _cos_central := 0.0
var _cos_periphery := 0.0


func _begin_checks() -> void:
	_eye = pawn.global_position + Vector3(0.0, eye_height, 0.0)
	var yaw := _eye_yaw()
	_facing = Vector2(-sin(yaw), -cos(yaw)) # Godot's forward is -Z, so yaw 0 faces -Z
	_cos_central = cos(deg_to_rad(central_cone_degrees * 0.5))
	_cos_periphery = cos(deg_to_rad(periphery_degrees * 0.5))


func _visibility(target: Pawn) -> float:
	var aim := target.global_position + Vector3(0.0, target_height, 0.0)
	var distance := _eye.distance_to(aim)
	if distance > sight_range:
		return 0.0
	var distance_factor := 1.0
	if distance > near_range:
		distance_factor = 1.0 - (distance - near_range) / maxf(sight_range - near_range, 0.001)
	# Angle, measured flat, between the way the eyes face and the way to the target. A bigger cosine means a smaller angle.
	var flat := Vector2(aim.x - _eye.x, aim.z - _eye.z)
	var angle_factor := 1.0
	if flat.length_squared() > 0.0001:
		var cosine := _facing.dot(flat.normalized())
		if cosine < _cos_periphery:
			return 0.0
		if cosine < _cos_central:
			angle_factor = periphery_multiplier
	return distance_factor * angle_factor * StatManager.detectability_of(target)


# Hands the checks to memory's store, then lets memory wake a decision and send its signals.
func _check_all(targets: Array, tick: int) -> void:
	var memory := pawn.ai_context.memory if pawn and pawn.ai_context else null
	if memory == null:
		return
	var store: Object = memory.get_store()
	_give_store(store)
	memory.announce_sight_results(store.sight_check(pawn, _eye_yaw(), targets, tick))


# The settings, filled again only if one changed or the tick rate did (most passes reuse them as they are).
func _settings_now() -> PackedFloat64Array:
	var rate := TickDriver.get_tick_rate()
	if _settings_dirty or rate != _settings_rate:
		_fill_settings()
		_settings_dirty = false
		_settings_rate = rate
		_store_given = null # the store needs the new ones
	return _settings


# Gives memory's store the settings and, for line of sight in C++ (the C++ store), the geometry, only when it doesn't have them yet.
# The GDScript store casts physics rays and has no geometry.
func _give_store(store: Object) -> void:
	var settings := _settings_now()
	var geometry: Object = SightGeometryFeeder.get_geometry()
	if store == _store_given and geometry == _geometry_given:
		return
	store.set_sight_settings(settings)
	if store.has_method(&"set_sight_geometry"):
		store.set_sight_geometry(geometry)
	_store_given = store
	_geometry_given = geometry


# The settings for memory's store and the sensing job, in AIMemoryStore.set_sight_settings' order.
func _fill_settings() -> void:
	_settings.resize(11)
	_settings[0] = TickDriver.per_tick_at_rate(fill_rate) # per tick at 60, so the same per second at any rate
	_settings[1] = near_range
	_settings[2] = sight_range
	_settings[3] = cos(deg_to_rad(central_cone_degrees * 0.5))
	_settings[4] = cos(deg_to_rad(periphery_degrees * 0.5))
	_settings[5] = periphery_multiplier
	_settings[6] = TickDriver.ticks_at_rate(max_gain_ticks)
	_settings[7] = eye_height
	_settings[8] = target_height
	_settings[9] = sight_blocking_mask
	_settings[10] = TickDriver.ticks_at_rate(manager.sense_interval_ticks if manager else 10) # the manager marks a change


# Which way the eyes face, as a yaw: the player's look, else where the AI was told to look, else the body's.
func _eye_yaw() -> float:
	var controllers := pawn.controller_manager
	if controllers and controllers.has_player():
		return controllers.look_yaw # where the player looks
	var hands := pawn.controller_manager.ai_controller as AIController if pawn.controller_manager else null
	if hands and hands.is_looking_at_point():
		return controllers.look_yaw if controllers else pawn.yaw # the AI looks where it was told to
	return pawn.yaw # otherwise, the way the body faces
