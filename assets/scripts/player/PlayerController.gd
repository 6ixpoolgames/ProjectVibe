## Written by Claude (claude-opus-5-5), 2026-11-07: one player's controls. It's a placeholder for now: enough to drive a pawn and aim a
## camera. It survives with no pawn, as Unreal's does, and PossessionCoordinator creates it and tells it which pawn it has.
##
## What it does:
##   - reads the player's devices, on this machine only
##   - holds the look direction, and tells the current arm where to look
##   - gives its pawn this tick's input, as plain data
##
## What it doesn't do: move anything. The pawn's movement module does that, so an RTS or a flying pawn needs no special controller.
##
## To drive it from a script, as a test or a replay viewer would, extend it and override the _read functions.
##
## Claude 2026-11-07: now extends ControllerBase, which holds pawn and pawn_changed. Each tick it builds an InputCommand, with named
## actions (jump, sprint, ...) mapped from keys by action_keys. Pawn spec sections 5 and 6.2.
##
## What happens in odd cases (all checked in pawn/tests/possession_selftest.gd):
##   - No pawn: it keeps reading look input, and nothing moves.
##   - An action missing from the project's input map: treated as not pressed.
class_name PlayerController
extends ControllerBase

enum LookMode {
	## The mouse is captured and turns the view, as in most action games.
	CAPTURED,
	## The mouse stays free and the view turns when it nears the edge of the screen, as the old camera arm did.
	SCREEN_EDGE,
}

@export var look_mode := LookMode.CAPTURED
## Radians turned per pixel the mouse moves, in CAPTURED mode.
@export var mouse_sensitivity := 0.0025
## How much of the screen counts as the edge, in SCREEN_EDGE mode, as a share of its width.
@export_range(0.01, 0.5, 0.01) var edge_zone := 0.125
## How fast the view turns at the very edge, in degrees per second, in SCREEN_EDGE mode.
@export var edge_turn_speed := 150.0
## On: clicking the ground walks there, along a nav path. A placeholder, until there's a navigation manager.
@export var click_to_move := false
## Which key in the project's input map presses which named action. The left side is an action from InputActions, and the right is an
## action in Project Settings > Input Map. An action with no key here is never pressed by the player.
# Claude 2026-11-07: new, replacing the fixed reads of move_jump and move_sprint.
# GDScript note: Dictionary[StringName, StringName] is a typed dictionary, so the inspector only accepts names on both sides.
@export var action_keys: Dictionary[StringName, StringName] = {&"jump": &"move_jump", &"sprint": &"move_sprint"}

## The real camera. It holds where it is while there's no view to follow.
var camera: PlayerCamera = null
## What the mouse or crosshair points at. It's off until something asks it.
var world_cursor: WorldCursor = null # Claude 2026-11-07: renamed from cursor, to match its class
## Where the player is looking, in radians.
var look_yaw := 0.0
var look_pitch := 0.0

var _driver: Node = null
# Claude 2026-11-07: replaces _jump_latched. Actions pressed since the last tick, as bits, so a tap shorter than a tick still counts.
var _latched_actions := 0
var _zoom_steps := 0.0
var _arm: CameraArm = null
var _move_path := PackedVector3Array()
var _move_path_index := 0


func _ready() -> void:
	# It stays out of the scene until it has a view. Godot makes the first camera it sees the active one, and this autoload's
	# child would come before any level's camera, taking over from cameras that don't ask to be current.
	camera = PlayerCamera.new()
	camera.name = "PlayerCamera"
	world_cursor = WorldCursor.new()
	world_cursor.name = "WorldCursor"
	add_child(world_cursor)
	_driver = get_node_or_null("/root/TickDriver")


func _exit_tree() -> void:
	if _driver:
		_driver.unregister(self)
	if is_instance_valid(camera) and not camera.is_inside_tree():
		camera.free() # it isn't our child yet, so nothing else would


# --- Called by PossessionCoordinator ---


## Takes this pawn, and lets go of any other. Null means none. Nothing else should call this: ask PossessionCoordinator.
func take_pawn(new_pawn: Pawn) -> void:
	if pawn == new_pawn:
		return
	_let_go_of_arm()
	pawn = new_pawn
	# Only ticks while it has a pawn, since there's nothing to do otherwise.
	if _driver:
		if pawn:
			_driver.register(self, -10) # first, so the pawn's input is ready for the rest of the tick
		else:
			_driver.unregister(self)
	if pawn == null:
		camera.set_view(null)
		_show_mouse()
		_latched_actions = 0 # Claude 2026-11-07: a press before letting go doesn't belong to the next pawn
	else:
		_arm = pawn.get_camera_arm()
		if _arm == null and pawn.get_default_view() == null:
			_arm = pawn.make_camera_arm()
		if _arm:
			_arm.set_active(true)
			# The view stays where the player was looking, as far as this arm allows.
			look_pitch = _arm.set_look(look_yaw, look_pitch if _had_pawn else _arm.get_pitch())
		if not camera.is_inside_tree():
			add_child(camera)
		camera.set_view(pawn.get_default_view())
		_capture_mouse()
		_had_pawn = true
	pawn_changed.emit(pawn)


# --- Ticks ---


## Gives the pawn its input for this tick. This runs on the machine that owns the pawn only, since only that machine has it here.
func _tick_input(_dt: float, tick: int) -> void:
	if not is_instance_valid(pawn):
		return
	pawn.apply_input(take_input_command(tick)) # Claude 2026-11-07: was apply_player_input, with sprint and jump as bools


## Claude 2026-11-07: this tick's input, from the devices. It uses up the presses saved since the last tick, so call it once per tick.
func take_input_command(_tick: int) -> InputCommand:
	var command := InputCommand.new()
	var wanted := _read_move()
	# Godot's forward is -Z, and move input's Y is backward, the way Input.get_vector gives it.
	command.move = Basis(Vector3.UP, look_yaw) * Vector3(wanted.x, 0.0, wanted.y)
	# Keys take over from a click. A path left unfinished is dropped.
	if wanted.length_squared() > 0.01:
		_move_path = PackedVector3Array()
	elif not _move_path.is_empty() and is_instance_valid(pawn):
		command.move = _next_path_direction()
	command.look_yaw = look_yaw
	command.look_pitch = look_pitch
	# Held now, or pressed and let go again since the last tick.
	command.held_actions = _latched_actions
	_latched_actions = 0
	for action: StringName in action_keys:
		if _read_action_held(action):
			command.held_actions |= InputActions.mask_of(action)
	return command


## Walks the pawn to this place along a nav path, if there is one, and in a straight line if there's no nav here. False if
## there's no pawn to move. Keys take over from it.
func move_to(world_point: Vector3) -> bool:
	if not is_instance_valid(pawn):
		return false
	_move_path = PackedVector3Array([world_point])
	_move_path_index = 0
	if Engine.has_singleton(&"NavServer"):
		var found: PackedVector3Array = Engine.get_singleton(&"NavServer").find_path_now(pawn.global_position, world_point, 0)
		if found.size() >= 2:
			_move_path = found
			_move_path_index = 1
	return true


## True while it's walking a path from move_to.
func is_following_path() -> bool:
	return not _move_path.is_empty()


func _next_path_direction() -> Vector3:
	while _move_path_index < _move_path.size():
		var to_corner := _move_path[_move_path_index] - pawn.global_position
		to_corner.y = 0.0 # a path's height between corners isn't the ground, so only its direction counts
		if to_corner.length() > 0.5:
			return to_corner.normalized()
		_move_path_index += 1
	_move_path = PackedVector3Array()
	return Vector3.ZERO


# --- Per rendered frame: never changes game state ---


func _process(delta: float) -> void:
	# Claude 2026-11-07: only with a pawn. A press with nothing to jump used to wait here, and jump the next pawn it got.
	# Claude 2026-11-07: now for every action in action_keys, not only jump.
	# Every key is read every frame, pawn or not, so a press with no pawn is used up rather than left waiting.
	var has_pawn := is_instance_valid(pawn)
	for action: StringName in action_keys:
		if _read_action_pressed(action) and has_pawn:
			_latched_actions |= InputActions.mask_of(action) # kept until a tick takes it, since a frame can have no ticks or several
	if look_mode == LookMode.SCREEN_EDGE:
		look_yaw += _edge_turn(delta)
	var extra := _read_look_extra()
	look_yaw = wrapf(look_yaw + extra.x, -PI, PI)
	look_pitch += extra.y
	if is_instance_valid(_arm):
		look_pitch = _arm.set_look(look_yaw, look_pitch)
		if _zoom_steps != 0.0:
			_arm.zoom(_zoom_steps)
	_zoom_steps = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and look_mode == LookMode.CAPTURED and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		look_yaw = wrapf(look_yaw - event.relative.x * mouse_sensitivity, -PI, PI)
		look_pitch -= event.relative.y * mouse_sensitivity
	elif event.is_action_pressed(&"scrollWheel_up", false, true) if InputMap.has_action(&"scrollWheel_up") else false:
		_zoom_steps -= 1.0
	elif event.is_action_pressed(&"scrollWheel_down", false, true) if InputMap.has_action(&"scrollWheel_down") else false:
		_zoom_steps += 1.0
	elif event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		# So a player can always get the mouse back.
		_show_mouse()
	elif click_to_move and is_instance_valid(pawn) and InputMap.has_action(&"left_click") and event.is_action_pressed(&"left_click"):
		var hit := world_cursor.query_now()
		if not hit.is_empty():
			move_to(hit["position"])
	elif event is InputEventMouseButton and event.pressed and is_instance_valid(pawn):
		_capture_mouse()


# --- Reading devices. Override these to drive it from a script. ---


## Which way to go, with X to the right and Y backward, up to length 1.
func _read_move() -> Vector2:
	if not _has_actions([&"move_left", &"move_right", &"move_forward", &"move_backward"]):
		return Vector2.ZERO
	return Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")


# Claude 2026-11-07: these two replace _read_sprint and _read_jump_pressed, and work for any named action.
## True while the key for this named action is down.
func _read_action_held(action: StringName) -> bool:
	var key: StringName = action_keys.get(action, &"")
	return key != &"" and InputMap.has_action(key) and Input.is_action_pressed(key)


## True on the rendered frame the key for this named action went down.
func _read_action_pressed(action: StringName) -> bool:
	var key: StringName = action_keys.get(action, &"")
	return key != &"" and InputMap.has_action(key) and Input.is_action_just_pressed(key)


## Any turning this frame beyond the mouse, as yaw and pitch in radians. For scripts, and later for gamepads.
func _read_look_extra() -> Vector2:
	return Vector2.ZERO


# --- Helpers ---


var _had_pawn := false


func _has_actions(actions: Array[StringName]) -> bool:
	for action in actions:
		if not InputMap.has_action(action):
			return false
	return true


## The old camera arm's way of turning: faster the closer the mouse is to the edge.
func _edge_turn(delta: float) -> float:
	var width := float(get_viewport().get_visible_rect().size.x)
	if width <= 0.0:
		return 0.0
	var mouse_x := get_viewport().get_mouse_position().x
	var zone := width * edge_zone
	var strength := 0.0
	if mouse_x < zone:
		strength = 1.0 - mouse_x / zone
	elif mouse_x > width - zone:
		strength = -(mouse_x - (width - zone)) / zone
	return deg_to_rad(edge_turn_speed) * clampf(strength, -1.0, 1.0) * delta


func _let_go_of_arm() -> void:
	if is_instance_valid(_arm):
		_arm.set_active(false)
		# An arm possession made goes away with it. A placed arm, or a hero's, stays.
		if _arm.spawned_by_possession and _arm.is_inside_tree():
			_arm.get_parent().remove_child(_arm)
			_arm.queue_free()
	_arm = null


func _capture_mouse() -> void:
	if look_mode == LookMode.CAPTURED and not click_to_move:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _show_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
