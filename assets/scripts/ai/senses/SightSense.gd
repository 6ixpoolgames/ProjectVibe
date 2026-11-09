## Written by Claude (claude-opus-5-5), 2026-11-09: sight, for basic stealth. A child of the pawn's AISensingManager. Pawn spec
## section 10.4.
##
## For each other-team pawn it checks, on a full pass or a refresh:
##     if there's no line of sight: no gain
##     gain = fill_rate × ticks_since_last_check × distance_factor × angle_factor × target.detectability
##   - ticks_since_last_check makes the checking rate not matter: a target checked every 10 ticks gets 10 ticks' worth. It's capped
##     at max_gain_ticks, so a pawn that wasn't sensing for a while (say while possessed with while_possessed OFF) doesn't jump.
##   - distance_factor: 1 inside near_range, falling in a straight line to 0 at sight_range.
##   - angle_factor: 1 inside the central cone, periphery_multiplier in the periphery, nothing outside it. Angles are measured flat,
##     from the direction the pawn's eyes face (below).
##   - target.detectability: the target pawn's own number, 1 normally. Games set it from their stealth rules.
## With the defaults, someone close and in front fills awareness in half a second, which is basically instant; someone 20 m away
## at the edge of the periphery takes several seconds.
##
## Line of sight is one ray, from eye_height above this pawn's feet to target_height above the target's feet. Only layers in
## sight_blocking_mask block it: the world (layer 1) by default, so other pawns don't hide each other.
##
## Which way the eyes face: where the AI is looking when it has a look target (AIController.look_at_point), or else the way the
## body faces. While a player has the pawn, where the player looks. So a goblin looking toward a noise sees that way, and a walking
## goblin sees where it's going.
##
## Refreshes check only the current target, the same way, so a tracked target stays fresh between full passes for one ray.
##
## Claude 2026-11-09: the checks themselves run in the pawn's memory store, AIMemoryStore in C++ when available (AIMemoryStoreGD
## otherwise), with these settings handed over each pass. visibility_of() and has_line_of_sight() below are the same rules in
## GDScript, for tests and debug readouts.
class_name SightSense
extends AISenseBase

## Awareness a fully visible target adds per tick: 1/30 fills it in 30 ticks, half a second.
@export_range(0.0, 1.0, 0.001, "or_greater") var fill_rate := 1.0 / 30.0
## Inside this distance, in metres, distance doesn't weaken sight at all.
@export_range(0.0, 200.0, 0.5, "or_greater") var near_range := 8.0
## Beyond this distance, in metres, nothing is seen.
@export_range(0.0, 500.0, 0.5, "or_greater") var sight_range := 25.0
## The width of the central cone, in degrees, where sight is at full strength.
@export_range(0.0, 360.0, 1.0) var central_cone_degrees := 90.0
## The width of everything it can see, in degrees, the central cone included. The part outside the central cone is the periphery.
@export_range(0.0, 360.0, 1.0) var periphery_degrees := 160.0
## How strongly the periphery sees, compared with the central cone.
@export_range(0.0, 1.0, 0.01) var periphery_multiplier := 0.3
## The most ticks one check can count, so a long gap doesn't give a huge gain at once.
@export_range(1, 600, 1, "or_greater") var max_gain_ticks := 30
## The height of the eyes above the pawn's feet, in metres.
@export var eye_height := 1.6
## The height on the target the ray aims at, in metres above its feet: about the chest.
@export var target_height := 1.0
## Physics layers that block sight. The world, layer 1, by default.
@export_flags_3d_physics var sight_blocking_mask := 1

# Reused for every ray, so checks create no new objects.
var _ray := PhysicsRayQueryParameters3D.new()
# Claude 2026-11-09: the settings handed to memory's store each pass, in the order AIMemoryStore.set_sight_settings takes them.
var _settings := PackedFloat64Array()
var _one_target: Array = [null] # reused for a refresh's single check


func get_range() -> float:
	return sight_range


## Claude 2026-11-09: the whole pass runs in memory's store (C++ when available, else GDScript), with this sense's settings.
func full_pass(candidates: Array[Pawn], tick: int) -> void:
	_check_all(candidates, tick)


## Claude 2026-11-09 (scaling spec step 2): the full pass with the sensing job's result: the job found the candidates and how visible
## each is, on a worker thread; this casts the rays and records, the same as full_pass would. AISensingManager calls it.
func full_pass_prepared(job: Object, tick: int) -> void:
	var memory := pawn.ai_memory if pawn else null
	if memory == null:
		return
	var store: Object = memory.get_store()
	_fill_settings()
	store.set_sight_settings(_settings)
	memory.announce_sight_results(store.sight_check_prepared(job, pawn, tick))


## Claude 2026-11-09 (step 2): asks the sensing job for next tick's full pass, with where the eyes face now and this sense's settings.
func ask_job(job: Object, reach: float, max_candidates: int) -> void:
	_fill_settings()
	job.add_request(pawn, _eye_yaw(), reach, max_candidates, _settings)


## Claude 2026-11-09: only the current target, one ray. Refreshing every remembered entity cost more than the full passes in a crowd
## (measured with ai_stress), and keeping a tracked target fresh is what the refresh is for.
func refresh(tick: int) -> void:
	var context := pawn.ai_context if pawn else null
	var target := context.current_target as Pawn if context else null
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
	return distance_factor * angle_factor * target.detectability


# Claude 2026-11-09: hands the checks to memory's store, then lets memory wake a decision and send its signals.
func _check_all(targets: Array, tick: int) -> void:
	var memory := pawn.ai_memory if pawn else null
	if memory == null:
		return
	var store: Object = memory.get_store()
	_fill_settings() # Claude 2026-11-09 (step 2): moved into a function, which the job's request uses too
	store.set_sight_settings(_settings)
	memory.announce_sight_results(store.sight_check(pawn, _eye_yaw(), targets, tick))


# Claude 2026-11-09 (step 2): the settings for memory's store and the sensing job, in AIMemoryStore.set_sight_settings' order.
func _fill_settings() -> void:
	_settings.resize(11)
	_settings[0] = fill_rate
	_settings[1] = near_range
	_settings[2] = sight_range
	_settings[3] = cos(deg_to_rad(central_cone_degrees * 0.5))
	_settings[4] = cos(deg_to_rad(periphery_degrees * 0.5))
	_settings[5] = periphery_multiplier
	_settings[6] = max_gain_ticks
	_settings[7] = eye_height
	_settings[8] = target_height
	_settings[9] = sight_blocking_mask
	_settings[10] = manager.sense_interval_ticks if manager else 10


func _eye_yaw() -> float:
	if pawn.has_player():
		return pawn.look_yaw # where the player looks
	var hands := pawn.controller_manager.ai_controller as AIController if pawn.controller_manager else null
	if hands and hands.is_looking_at_point():
		return pawn.look_yaw # the AI looks where it was told to
	return pawn.yaw # otherwise, the way the body faces
