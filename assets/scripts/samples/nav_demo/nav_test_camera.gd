## Written by Claude (claude-opus-5-5), 2026-11-03: simple orbit camera for the nav test scene.
## WASD: move.  Middle mouse drag: orbit.  Mouse wheel: zoom.  Q/E: rotate.
extends Camera3D

@export var terrain: NavTestTerrain
@export var move_speed := 30.0
@export var distance := 45.0
@export var yaw := 0.6
@export var pitch := -0.9

var _focus := Vector3.ZERO
var _orbiting := false


func get_focus() -> Vector3:
	return _focus


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_orbiting = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance = maxf(5.0, distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance = minf(250.0, distance * 1.1)
	elif event is InputEventMouseMotion and _orbiting:
		yaw -= event.relative.x * 0.005
		pitch = clampf(pitch - event.relative.y * 0.005, -1.5, -0.1)


func _process(delta: float) -> void:
	var input := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	yaw += (float(Input.is_physical_key_pressed(KEY_Q)) - float(Input.is_physical_key_pressed(KEY_E))) * delta * 1.5
	var forward := Vector3(sin(yaw), 0.0, cos(yaw))
	var right := Vector3(forward.z, 0.0, -forward.x)
	_focus += (right * input.x + forward * input.y) * move_speed * delta * (distance / 45.0)
	if terrain:
		_focus.y = terrain.height_at(_focus.x, _focus.z)
	var offset := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch)) * distance
	global_position = _focus + offset
	look_at(_focus, Vector3.UP)
