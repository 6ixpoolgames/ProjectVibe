## Written by Claude (claude-opus-5-5), 2026-11-04: the sample pawn with an attack, showing multiplayer end to end.
## Click to shoot where you're looking. Input goes to the server, which checks the hit with lag compensation and takes
## health off the target. Health is a sync property, so every client sees the result in the next snapshot.
## A teaching example, like TickSamplePawn. The real pawn splits this into abilities (pawn spec).
##
## Rules:
##   - Only the authority decides hits and damage. A client never changes another entity (netcode spec section 11.2).
##   - The server limits the fire rate itself, whatever the client asks for.
##   - Offline, it still works: the local machine is the authority.
extends TickSamplePawn
class_name NetSamplePawn

@export var attack_range: float = 100.0
@export var attack_damage: int = 10
@export var attack_cooldown_seconds: float = 0.25
@export var start_health: int = 100

# Input: what the player wants this tick.
var wants_attack := false
var aim_dir := Vector3.FORWARD
## How far behind our own tick others were drawn when we fired. The server limits it.
var view_ticks_behind := 0.0

## How much health is left. A sync property: only the server changes it.
var health: int = 100
var shots_fired := 0
var hits_landed := 0

var _entity: NetworkEntity = null
var _next_attack_tick := 0
var _attack_latched := false


func _on_network_role(entity: NetworkEntity) -> void:
	super(entity)
	if entity.is_local:
		body_color = Color(0.25, 0.5, 0.95) # so you can tell which pawn is yours


func _ready() -> void:
	super()
	health = start_health
	_entity = _find_entity()


func _process(delta: float) -> void:
	super(delta)
	if brain == Brain.PLAYER and Input.is_action_just_pressed(&"left_click"):
		_attack_latched = true


func _tick_input(dt: float, tick: int) -> void:
	super(dt, tick)
	if brain == Brain.PLAYER:
		wants_attack = _attack_latched
		_attack_latched = false
		aim_dir = _aim_from_mouse()
		view_ticks_behind = _session_view_ticks_behind()


func _tick_simulate(dt: float, tick: int) -> void:
	super(dt, tick)
	if wants_attack and _entity and _entity.role == NetworkEntity.Role.AUTHORITY and tick >= _next_attack_tick:
		_next_attack_tick = tick + _seconds_to_ticks(attack_cooldown_seconds)
		_fire()


func take_damage(amount: int) -> void:
	health = maxi(health - amount, 0)


func sanitize_network_input(values: Dictionary) -> Dictionary:
	var clean := super(values)
	clean["wants_attack"] = values.get("wants_attack", false) is bool and values.get("wants_attack", false)
	var aim: Variant = values.get("aim_dir", Vector3.FORWARD)
	clean["aim_dir"] = aim.normalized() if aim is Vector3 and aim.is_finite() and aim.length_squared() > 0.0001 else Vector3.FORWARD
	var behind: Variant = values.get("view_ticks_behind", 0.0)
	clean["view_ticks_behind"] = behind if behind is float and is_finite(behind) else 0.0
	return clean


func _network_input_missing() -> void:
	super()
	wants_attack = false


func _fire() -> void:
	shots_fired += 1
	var origin := global_position + Vector3(0, 1.4, 0)
	var hit := LagCompensation.hitscan(_entity, origin, aim_dir, attack_range, view_ticks_behind)
	if hit.is_empty():
		return
	var target: NetworkEntity = hit["entity"]
	if target and target.get_parent().has_method(&"take_damage"):
		hits_landed += 1
		target.get_parent().take_damage(attack_damage)


func _session_view_ticks_behind() -> float:
	return _entity.session.get_view_ticks_behind() if _entity and _entity.session else 0.0


## Where the mouse points on the ground, as a level direction from us. Without a camera, straight ahead.
func _aim_from_mouse() -> Vector3:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return aim_dir
	var mouse := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse)
	var along := camera.project_ray_normal(mouse)
	if absf(along.y) < 0.001:
		return aim_dir
	var on_ground := from + along * ((global_position.y + 1.4 - from.y) / along.y)
	var flat := on_ground - (global_position + Vector3(0, 1.4, 0))
	flat.y = 0.0
	return flat.normalized() if flat.length_squared() > 0.01 else aim_dir


func _find_entity() -> NetworkEntity:
	for child in get_children():
		if child is NetworkEntity:
			return child
	return null
