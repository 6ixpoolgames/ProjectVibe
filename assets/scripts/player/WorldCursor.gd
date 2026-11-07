## Written by Claude (claude-opus-5-5), 2026-11-07: what the mouse or crosshair points at in the world. A module of PlayerController.
## It's Unreal's GetHitResultUnderCursor, with the polling made explicit. It does nothing and costs nothing until something asks.
##
## Two ways to use it:
##   One answer, right now, such as on a click:
##     var hit := controller.world_cursor.query_now()
##   Watching, such as a hover highlight or a placement preview, at a rate you choose:
##     controller.world_cursor.acquire(self, 20.0)   # 20 times a second. 0 means every frame
##     controller.world_cursor.hit_changed.connect(...)
##     controller.world_cursor.release(self)         # or just get freed or leave the scene, which counts as releasing
##
## With several users, the fastest rate anyone asked for wins. When the last one is gone, it stops by itself.
##
## An answer is a Dictionary: {"position", "normal", "collider"}. It's empty if the ray hit nothing, or if there's no camera.
## A captured mouse points at the middle of the screen, as a crosshair does. A free mouse points where it is.
##
## Its ray is a physics query outside the physics step. That's safe with Godot's default setting, where physics doesn't run
## on its own thread. A project that turns that on would have to move this.
##
## A note on rates: anything drawn at the cursor looks laggy at a low rate, so a visible cursor wants a high one.
class_name WorldCursor
extends Node

## Sent when watching, each time there's a new answer.
signal hit_changed(hit: Dictionary)

## What the ray can hit. By default the ground's layer and the pawns' layer.
@export_flags_3d_physics var collision_mask := 3
## How far the ray goes, in metres.
@export var max_distance := 1000.0

## The last answer. Empty means nothing is there, and it's only kept up to date while something is watching.
var last_hit := {}

var _users := {} # object -> how many times a second it asked for, with 0 meaning every frame
var _interval := 0.0
var _timer := 0.0


func _ready() -> void:
	set_process(false)


## Starts watching for this user, at this many times a second. 0 means every frame. Asking again changes its rate.
func acquire(user: Object, times_per_second: float = 0.0) -> void:
	if user == null:
		return
	if not _users.has(user) and user is Node:
		(user as Node).tree_exited.connect(release.bind(user), CONNECT_ONE_SHOT)
	_users[user] = maxf(times_per_second, 0.0)
	_update_rate()


## Stops watching for this user. When nobody is left, it stops altogether.
func release(user: Object) -> void:
	if not _users.has(user):
		return
	_users.erase(user)
	# GDScript note: is_instance_valid guards a freed object, whose signals can't be touched any more.
	if is_instance_valid(user) and user is Node and (user as Node).tree_exited.is_connected(release):
		(user as Node).tree_exited.disconnect(release)
	_update_rate()


func is_watching() -> bool:
	return is_processing()


func get_user_count() -> int:
	return _users.size()


## One answer, right now, whoever else is watching.
func query_now() -> Dictionary:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return {}
	var screen_point := _screen_point(camera)
	var from := camera.project_ray_origin(screen_point)
	var query := PhysicsRayQueryParameters3D.create(from, from + camera.project_ray_normal(screen_point) * max_distance, collision_mask)
	var hit: Dictionary = camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}
	return {"position": hit["position"], "normal": hit["normal"], "collider": hit["collider"]}


func _process(delta: float) -> void:
	_forget_freed_users()
	if _users.is_empty():
		return
	if _interval > 0.0:
		_timer -= delta
		if _timer > 0.0:
			return
		_timer += _interval
		_timer = maxf(_timer, 0.0)
	last_hit = query_now()
	hit_changed.emit(last_hit)


func _update_rate() -> void:
	_forget_freed_users()
	var watching := not _users.is_empty()
	set_process(watching)
	if not watching:
		last_hit = {}
		return
	var fastest := 0.0
	var every_frame := false
	for user: Object in _users:
		var rate: float = _users[user]
		if rate <= 0.0:
			every_frame = true
		fastest = maxf(fastest, rate)
	_interval = 0.0 if every_frame else 1.0 / fastest
	_timer = 0.0


## Something that isn't a node can't say it's gone, so this notices.
func _forget_freed_users() -> void:
	for user: Variant in _users.keys():
		if not is_instance_valid(user):
			_users.erase(user)
	if _users.is_empty() and is_processing():
		set_process(false)
		last_hit = {}


func _screen_point(camera: Camera3D) -> Vector2:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return camera.get_viewport().get_visible_rect().size * 0.5
	return camera.get_viewport().get_mouse_position()
