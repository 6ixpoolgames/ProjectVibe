## Written by Claude (claude-opus-5-5), 2026-11-06: a plain test pawn that walks a list of points on a streamed terrain.
## A teaching example and test tool, not the real pawn, which isn't connected to chunk streaming yet.
##
## It shows the rule the owner wants for real controllers: a pawn under player control keeps the world loaded by default,
## and a pawn under AI control only does if its bool is on.
##
class_name StreamingSamplePawn
extends CharacterBody3D

## The terrain it walks on. Without one, it stands still.
@export var terrain: Terrain
## Walking speed, in metres per second.
@export var speed := 6.0
## How strongly it falls, in metres per second per second.
@export var gravity := 20.0
## Starts again from the first point after reaching the last.
@export var loop_route := false
## On: this pawn counts as player controlled, so it keeps the world loaded around it.
@export var is_player_controlled := true:
	set(value):
		is_player_controlled = value
		_update_source()
		_update_ai_activity()
## Whether an AI controlled pawn keeps the world loaded around it. It has no effect when is_player_controlled is on.
@export var ai_loads_chunks := false:
	set(value):
		ai_loads_chunks = value
		_update_source()

## The points to walk to, in order, as positions in the world. Only X and Z are used, because it follows the ground.
var route := PackedVector3Array()
## The node that makes this pawn keep the world loaded.
var source: StreamingSource

# Numbers that tests read.
var ticks_without_ground := 0 ## physics ticks with no chunk built underneath. It should stay 0
var worst_below_ground := 0.0 ## how far under the ground it has ever been, in metres
var distance_walked := 0.0 ## in metres, as seen from above
var finished_route := false

var _next_point := 0


func _init() -> void:
	# A capsule the size of the smallest pawn the nav system expects.
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.8
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position.y = 0.9 # so this node's position is at the pawn's feet, which is what nav paths give
	add_child(collision)

	floor_snap_length = 1.5 # stays on the ground going downhill, instead of taking off
	floor_max_angle = deg_to_rad(60.0)

	source = StreamingSource.new()
	add_child(source)
	_update_source()


func _enter_tree() -> void:
	add_to_group(TerrainBodyLifter.GROUP)
	_update_ai_activity()


func _exit_tree() -> void:
	var game_mode: Node = get_node_or_null("/root/GameMode")
	if game_mode and game_mode.ai_activity:
		game_mode.ai_activity.remove_pawn(self)


## GameMode's AIActivityModule calls this. Everything about the pawn stays as it is, and it simply stops moving.
func set_simulation_active(active: bool) -> void:
	set_physics_process(active)


## Starts walking a new list of points.
func set_route(points: PackedVector3Array) -> void:
	route = points
	_next_point = 0
	finished_route = false


func _physics_process(delta: float) -> void:
	if not is_instance_valid(terrain):
		return
	if not terrain.has_chunk(terrain.chunk_of(global_position)):
		ticks_without_ground += 1

	var flat_velocity := _walk_velocity()
	velocity.x = flat_velocity.x
	velocity.z = flat_velocity.z
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	var before := global_position
	move_and_slide()
	distance_walked += Vector2(global_position.x - before.x, global_position.z - before.z).length()
	worst_below_ground = maxf(worst_below_ground, terrain.height_at(global_position.x, global_position.z) - global_position.y)


## Which way to walk to reach the next point, as a velocity. It's zero with nothing left to walk to.
func _walk_velocity() -> Vector3:
	while _next_point < route.size():
		var target := route[_next_point]
		var away := Vector3(target.x - global_position.x, 0.0, target.z - global_position.z)
		# Close enough to count as there. It's more than one tick's walk, so a fast pawn can't overshoot and circle.
		if away.length() > maxf(0.5, speed / 30.0):
			return away.normalized() * speed
		_next_point += 1
		if _next_point >= route.size() and loop_route:
			_next_point = 0
	finished_route = true
	return Vector3.ZERO


## An AI pawn gets switched off where no source keeps the ground loaded. A player's pawn is never watched, because it always has its source.
func _update_ai_activity() -> void:
	if not is_inside_tree():
		return
	var game_mode: Node = get_node_or_null("/root/GameMode")
	if game_mode == null or game_mode.ai_activity == null:
		return
	if is_player_controlled:
		game_mode.ai_activity.remove_pawn(self)
	else:
		game_mode.ai_activity.add_pawn(self)


func _update_source() -> void:
	if source != null:
		source.active = is_player_controlled or ai_loads_chunks
