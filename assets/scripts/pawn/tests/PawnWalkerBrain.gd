## Written by Claude (claude-opus-5-5), 2026-11-07: a test tool that walks a Pawn along nav paths, instead of a player's keys. It's the same
## walking as NetTestPawn's, for the real motor. Its choices depend only on the tick and the pawn's id, so runs are repeatable.
## It runs where the pawn's input is decided: on the owner's machine, or on the server for a pawn nobody owns.
class_name PawnWalkerBrain
extends Node

const CORNER_REACHED := 0.7

## The terrain to walk on. With none, it stands still.
static var terrain: TerrainGenerator = null
## What it does: "walk" or "idle".
var mode := "walk"

# Numbers that tests read.
var paths_found := 0
var path_failures := 0
var times_stuck := 0
var distance_walked := 0.0
var ticks_without_ground := 0 ## ticks with no chunk built underneath, which should stay 0

var _pawn: Pawn = null
var _entity: NetworkEntity = null
var _driver: Node = null
var _key := 0
var _path := PackedVector3Array()
var _path_index := 0
var _next_path_tick := 0
var _progress_check_tick := 0
var _progress_from := Vector3.ZERO
var _last_position := Vector3.ZERO
var _has_last_position := false
var _command := InputCommand.new() # Claude 2026-11-07: reused every tick, so a big swarm doesn't make one per pawn per tick


func _ready() -> void:
	name = "WalkerBrain"
	_pawn = get_parent() as Pawn
	_driver = get_node_or_null("/root/TickDriver")
	if _pawn and _pawn.has_meta(&"network_entity"):
		_entity = _pawn.get_meta(&"network_entity")
		_key = _entity.entity_id
	if _driver:
		_driver.register(self, 0) # after a PlayerController's -10, so this wins while it's driving


func _exit_tree() -> void:
	if _driver:
		_driver.unregister(self)


func _tick_input(_dt: float, tick: int) -> void:
	if _pawn == null or not _is_ours_to_drive() or not _pawn.is_simulation_active():
		return
	if terrain != null and not terrain.has_chunk(terrain.chunk_of(_pawn.position)):
		ticks_without_ground += 1
	if mode != "walk":
		_drive(Vector3.ZERO, false)
		return
	_walk(tick)


func _is_ours_to_drive() -> bool:
	if _entity == null:
		return true
	return _entity.is_local or (_entity.role == NetworkEntity.Role.AUTHORITY and _entity.owner_peer == 0)


func _walk(tick: int) -> void:
	var at := _pawn.position
	if _has_last_position:
		distance_walked += Vector2(at.x - _last_position.x, at.z - _last_position.z).length()
	_has_last_position = true
	_last_position = at
	if _path_index >= _path.size():
		_drive(Vector3.ZERO, false)
		if tick >= _next_path_tick:
			_next_path_tick = tick + 30
			_find_new_path(tick)
		return
	var to_corner := _path[_path_index] - at
	to_corner.y = 0.0
	if to_corner.length() < CORNER_REACHED:
		_path_index += 1
		_drive(Vector3.ZERO, false)
		return
	_drive(to_corner.normalized(), hash(Vector2i(tick / 120, _key)) % 4 == 0)
	# Not getting anywhere for a second: something's in the way, so it gives up on this path.
	if tick >= _progress_check_tick:
		var moved := Vector2(at.x - _progress_from.x, at.z - _progress_from.z).length()
		if _progress_check_tick > 0 and moved < 1.0:
			times_stuck += 1
			_path = PackedVector3Array()
			_path_index = 0
		_progress_from = at
		_progress_check_tick = tick + 60


func _drive(direction: Vector3, sprint: bool) -> void:
	# The look direction stays whatever it is, so a PlayerController's reaches the server.
	# Claude 2026-11-07: an InputCommand now, with sprint as a named action.
	_command.move = direction
	_command.look_yaw = _pawn.look_yaw
	_command.look_pitch = _pawn.look_pitch
	_command.held_actions = InputActions.mask_of(&"sprint") if sprint else 0
	_pawn.apply_input(_command)


func _find_new_path(tick: int) -> void:
	if terrain == null or not Engine.has_singleton(&"NavServer"):
		return
	var pick := RandomNumberGenerator.new()
	pick.seed = hash(Vector2i(_key, paths_found + path_failures))
	var heading_pick := RandomNumberGenerator.new()
	heading_pick.seed = hash(_key)
	var heading := heading_pick.randf() * TAU + pick.randf_range(-0.7, 0.7)
	var goal := _pawn.position + Vector3(cos(heading), 0.0, sin(heading)) * 30.0
	if not terrain.has_chunk(terrain.chunk_of(goal)):
		path_failures += 1
		return
	goal.y = terrain.height_at(goal.x, goal.z)
	var found: PackedVector3Array = Engine.get_singleton(&"NavServer").find_path_now(_pawn.position, goal, 0)
	if found.size() < 2:
		path_failures += 1
		return
	paths_found += 1
	_path = found
	_path_index = 1
	_progress_from = _pawn.position
	_progress_check_tick = tick + 60
