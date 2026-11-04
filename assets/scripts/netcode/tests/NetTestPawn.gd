## Written by Claude (claude-opus-5-5), 2026-11-04: a pawn driven by a script instead of keys, for testing multiplayer.
## Everything else about it is NetSamplePawn. The script's choices depend only on the tick, so runs are repeatable.
## Modes (set on the static default_mode before connecting):
##   seek     walks toward the arena's middle with a random new direction every 10 ticks, so pawns keep bumping
##   strafe   walks back and forth along Z in a straight line, a steady target
##   shoot    stands still and fires at the first other pawn where it's drawn, every 30 ticks
##   lead     the same, but aims ahead of where it's drawn, by a fixed distance. Used to check attacks behave past the rewind cap
##   walk     picks random points and follows nav paths to them, for testing on terrain (needs NavServer)
##   idle     does nothing
extends NetSamplePawn
class_name NetTestPawn

static var default_mode: String = "seek"
## What pawns nobody owns do, on the server.
static var ai_mode: String = "idle"
static var lead_seconds: float = 0.0
## A shooter's claim of how far behind it sees, whatever's true. Below 0, it tells the truth.
static var forced_claim: float = -1.0

var mode: String = "idle"
var corrections_seen := 0
## Server: stretches of ticks with no input from this pawn's client, as [first, last]. For finding out when inputs go missing.
var missing_stretches: Array = []
var _local := false
var _key := 0

# Walking on nav paths. None of this is rolled back: it only decides inputs, and a replay uses the inputs already saved.
const WALK_RADIUS := 45.0
const CORNER_REACHED := 0.7
var paths_found := 0
var path_failures := 0
var times_stuck := 0
var distance_walked := 0.0
var _path := PackedVector3Array()
var _path_index := 0
var _next_path_tick := 0
var _progress_check_tick := 0
var _progress_from := Vector3.ZERO
var _last_position := Vector3.ZERO


func _on_network_role(entity: NetworkEntity) -> void:
	var nobody_owns := entity.role == NetworkEntity.Role.AUTHORITY and entity.owner_peer == 0
	_local = entity.is_local or nobody_owns
	mode = default_mode if entity.is_local else (ai_mode if nobody_owns else "idle")
	_key = entity.entity_id
	brain = Brain.NETWORK # the keyboard and the wander brain stay out of it


func _tick_input(dt: float, tick: int) -> void:
	super(dt, tick)
	if not _local:
		return
	wants_sprint = false
	wants_jump = false
	wants_attack = false
	match mode:
		"seek":
			_seek(tick)
		"strafe":
			var going_up := (tick / 120) % 2 == 0
			move_dir = Vector3(0, 0, 1.0 if going_up else -1.0)
		"shoot", "lead":
			move_dir = Vector3.ZERO
			_shoot(tick)
		"walk":
			_walk(tick)
		_:
			move_dir = Vector3.ZERO


func _network_input_missing() -> void:
	super()
	var tick: int = _driver.tick
	if not missing_stretches.is_empty() and int(missing_stretches[-1][1]) == tick - 1:
		missing_stretches[-1][1] = tick
	else:
		missing_stretches.append([tick, tick])


func _on_network_corrected(jump: Variant) -> void:
	super(jump)
	corrections_seen += 1


func _walk(tick: int) -> void:
	distance_walked += Vector2(position.x - _last_position.x, position.z - _last_position.z).length()
	_last_position = position
	if _path_index >= _path.size():
		move_dir = Vector3.ZERO
		if tick >= _next_path_tick:
			_next_path_tick = tick + 30
			_find_new_path(tick)
		return
	var to_corner := _path[_path_index] - position
	to_corner.y = 0.0
	if to_corner.length() < CORNER_REACHED:
		_path_index += 1
		move_dir = Vector3.ZERO
		return
	move_dir = to_corner.normalized()
	wants_sprint = hash(Vector2i(tick / 120, _key)) % 4 == 0
	# Not getting anywhere for a second: something's in the way, so it gives up on this path.
	if tick >= _progress_check_tick:
		var moved := Vector2(position.x - _progress_from.x, position.z - _progress_from.z).length()
		if _progress_check_tick > 0 and moved < 1.0:
			times_stuck += 1
			_path = PackedVector3Array()
			_path_index = 0
		_progress_from = position
		_progress_check_tick = tick + 60


func _find_new_path(tick: int) -> void:
	if not Engine.has_singleton(&"NavServer"):
		return
	var pick := RandomNumberGenerator.new()
	pick.seed = hash(Vector2i(_key, paths_found + path_failures))
	var goal := Vector3(pick.randf_range(-WALK_RADIUS, WALK_RADIUS), 0.0, pick.randf_range(-WALK_RADIUS, WALK_RADIUS))
	var found: PackedVector3Array = Engine.get_singleton(&"NavServer").find_path_now(position, goal, 0)
	if found.size() < 2:
		path_failures += 1
		return
	paths_found += 1
	_path = found
	_path_index = 1
	_progress_from = position
	_progress_check_tick = tick + 60


func _seek(tick: int) -> void:
	var change := RandomNumberGenerator.new()
	change.seed = hash(Vector2i(tick / 10, _key))
	var angle := change.randf() * TAU
	var to_middle := -position
	to_middle.y = 0.0
	var toward: Vector3 = to_middle.normalized() if to_middle.length_squared() > 0.01 else Vector3.ZERO
	move_dir = (toward * 0.7 + Vector3(cos(angle), 0.0, sin(angle))).normalized()
	wants_sprint = change.randf() > 0.7
	wants_jump = tick % 91 == _key % 91


func _shoot(tick: int) -> void:
	if _entity == null or _entity.session == null:
		return
	for other: NetworkEntity in _entity.session.get_entities():
		if other == _entity:
			continue
		var target: Node3D = other.get_parent()
		var aim_at := target.global_position + Vector3(0, 0.9, 0)
		if mode == "lead" and "velocity" in target:
			aim_at += target.velocity * lead_seconds
		aim_dir = (aim_at - (global_position + Vector3(0, 1.4, 0))).normalized()
		view_ticks_behind = forced_claim if forced_claim >= 0.0 else _session_view_ticks_behind()
		wants_attack = tick % 30 == 0 and _entity.session.render_tick >= 0.0
		return
