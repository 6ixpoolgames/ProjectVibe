## Written by Claude (claude-opus-5-5), 2026-11-07: holds a VirtualCamera out from a pawn, following a look direction, and pulls it in
## so walls don't come between the camera and the pawn. It's Unreal's spring arm, as a plain node.
##
## It's idle unless it's active, which is when a player is looking through it. An idle arm does no work and reads nothing, and
## it never reads input itself: PlayerController tells it where to look. So AI or a cutscene could drive it just the same.
##
## Its one collision check each frame is a physics query outside the physics step. That's safe with Godot's default setting,
## where physics doesn't run on its own thread. A project that turns that on would have to move this.
class_name CameraArm
extends Node3D

## The settings. Empty means the defaults.
@export var preset: CameraPreset

## True if possession made this arm, so it goes again when possession ends. An arm placed in a scene stays.
var spawned_by_possession := false

var _view: VirtualCamera = null
var _length := 6.0
var _pitch := 0.0
var _yaw := 0.0
var _exclude: Array[RID] = []
var _sphere := SphereShape3D.new()
var _shown_length := 0.0 # how long the arm really is right now, after walls


func _ready() -> void:
	if preset == null:
		preset = CameraPreset.new()
	position = Vector3(preset.shoulder_offset, preset.mount_height, 0.0)
	_length = clampf(preset.arm_length, 0.0, maxf(preset.max_length, preset.arm_length))
	_pitch = clampf(deg_to_rad(preset.start_pitch), deg_to_rad(preset.min_pitch), deg_to_rad(preset.max_pitch))
	_view = _find_view()
	if _view == null:
		_view = VirtualCamera.new()
		_view.name = "VirtualCamera"
		add_child(_view)
	_view.fov = preset.fov
	_sphere.radius = maxf(preset.collision_radius, 0.01)
	set_process(false)
	_shown_length = _length
	_place_view(_shown_length)


## The view on the end of the arm.
func get_view() -> VirtualCamera:
	return _view


## Stops this body pulling the camera in, normally the pawn holding the arm.
func ignore_body(body: CollisionObject3D) -> void:
	_exclude.append(body.get_rid())


## Starts or stops the arm's work. Only the arm a player is looking through needs to run.
func set_active(active: bool) -> void:
	set_process(active)


## Where to look, as a yaw and pitch in radians. Pitch is limited to the preset's range, and the result is returned.
func set_look(new_yaw: float, new_pitch: float) -> float:
	_yaw = new_yaw
	_pitch = clampf(new_pitch, deg_to_rad(preset.min_pitch), deg_to_rad(preset.max_pitch))
	return _pitch


func get_pitch() -> float:
	return _pitch


## Changes the arm's length by this many steps. Positive is further out.
func zoom(steps: float) -> void:
	_length = clampf(_length + steps * preset.zoom_step, preset.min_length, preset.max_length)


func get_length() -> float:
	return _length


## How long the arm actually is right now, after walls.
func get_current_length() -> float:
	return _shown_length


func _process(delta: float) -> void:
	var allowed := minf(_length, _how_far_out())
	if allowed < _shown_length:
		_shown_length = allowed # at once, so it never goes through anything
	else:
		_shown_length = move_toward(_shown_length, allowed, preset.return_speed * delta)
	_place_view(_shown_length)


func _place_view(length: float) -> void:
	# Yaw and pitch here are world directions, because the arm hangs from Visual, which never rotates.
	var look := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	rotation = look.get_euler()
	_view.position = Vector3(0.0, 0.0, length)


## Casts the camera's sphere out along the arm, and returns how far it gets.
func _how_far_out() -> float:
	if _length <= 0.0 or not is_inside_tree():
		return _length
	var look := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	var from := global_position
	var motion := (look * Vector3.BACK) * _length
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _sphere
	query.transform = Transform3D(Basis.IDENTITY, from)
	query.motion = motion
	query.collision_mask = preset.collision_mask
	query.exclude = _exclude
	var result := get_world_3d().direct_space_state.cast_motion(query)
	return _length * result[0]


func _find_view() -> VirtualCamera:
	for child in get_children():
		if child is VirtualCamera:
			return child
	return null
