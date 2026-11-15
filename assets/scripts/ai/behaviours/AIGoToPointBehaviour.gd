## Written by Claude (claude-opus-5-5), 2026-11-15: walks to a meeting point, the owner's request: in the mass battle, every faction
## marches to the middle and fights there, instead of wandering near its spawner. Like Unreal's target points: the point is a node
## in a Godot group (point_group, "rally_point" by default), placed in the level, so pawns spawned at any time find it.
##
## When it's available: there's a node in point_group, and the pawn is further than arrive_radius from it. Allowed in Idle, the same
## as Wander, with a score just above Wander's (0.15 against 0.1), so an idle pawn marches, anything it notices on the way (Alert,
## Combat) takes over, and once it's there, Wander takes over and it mills about.
##
## How it walks: in legs of at most leg_metres toward the point, each one a move_to, so each path stays short. Nav is only built near
## streaming sources (StreamingSource.nav_distance), so one path all the way across a big level might not exist yet, while a short
## leg does. Each pawn walks a little to one side of the straight line (up to spread_metres, its own offset from its random numbers),
## so a crowd marches as a band, not in single file. A leg that can't be walked is tried again a few metres shorter on the next tick.
##
## It never finishes on its own: it returns RUNNING, and stops being available once the pawn has arrived.
class_name AIGoToPointBehaviour
extends AIBehaviourBase

## The Godot group the point is in. The nearest node in it is the point.
@export var point_group: StringName = &"rally_point"
## Close enough, in metres. Inside this the behaviour isn't available, so Wander takes over.
@export_range(0.5, 500.0, 0.5, "or_greater") var arrive_radius := 15.0
## The longest leg it walks at once, in metres.
@export_range(2.0, 200.0, 0.5, "or_greater") var leg_metres := 30.0
## How far to one side of the straight line this pawn walks, at most, in metres.
@export_range(0.0, 100.0, 0.5, "or_greater") var spread_metres := 6.0

const SIDE_SALT := 0x60A1

var _point: Node3D = null
var _shorten := 0.0 # metres taken off the next leg after one that couldn't be walked


func _init() -> void:
	super()
	allowed_states = [&"Idle"]
	max_score = 0.15
	min_score = 0.15
	tick_interval_ticks = 5 # it only needs to notice when a leg ends


func is_available(_context: AIContextComponent) -> bool:
	_point = _nearest_point()
	return _point != null and _flat_distance(_point.global_position) > arrive_radius


func enter(_context: AIContextComponent) -> void:
	_shorten = 0.0


func tick(context: AIContextComponent) -> Status:
	var hands := context.controller
	if hands == null or pawn == null or not is_instance_valid(_point):
		return Status.FAILED
	if hands.is_following_order():
		return Status.RUNNING
	var to := _point.global_position - pawn.global_position
	to.y = 0.0
	var distance := to.length()
	if distance <= arrive_radius:
		return Status.RUNNING # arrived; the next decision picks something else
	var ahead := to / distance
	# Its own side of the line, the same every leg: from its number, not the tick, so it doesn't zig-zag.
	var side := (context.random_unit_at(0, SIDE_SALT) * 2.0 - 1.0) * spread_metres
	var across := Vector3(-ahead.z, 0.0, ahead.x)
	var leg := maxf(minf(leg_metres - _shorten, distance), 2.0)
	var target := pawn.global_position + ahead * leg + across * side * minf(1.0, distance / leg_metres)
	if hands.move_to(target):
		_shorten = 0.0
	else:
		_shorten = minf(_shorten + 5.0, leg_metres - 2.0) # shorter next time, toward ground nav has built
	return Status.RUNNING


func exit(context: AIContextComponent, _reason: String) -> void:
	if context and context.controller:
		context.controller.stop()


func _nearest_point() -> Node3D:
	if pawn == null or not pawn.is_inside_tree():
		return null
	var best: Node3D = null
	var best_distance := INF
	for node in pawn.get_tree().get_nodes_in_group(point_group):
		var point := node as Node3D
		if point == null:
			continue
		var distance := _flat_distance(point.global_position)
		if distance < best_distance:
			best = point
			best_distance = distance
	return best


func _flat_distance(point: Vector3) -> float:
	return Vector2(point.x - pawn.global_position.x, point.z - pawn.global_position.z).length()
