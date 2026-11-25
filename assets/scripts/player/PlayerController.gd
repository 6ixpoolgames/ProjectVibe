# Written by Claude (claude-opus-5-5), 2026-11-07. History: player/CHANGELOG.md.
## One player's controls: reads their devices, aims their camera, and gives their pawn input.
##
## Survives with no pawn, as Unreal's does. PossessionCoordinator creates it and tells it which pawn it has. It reads the player's
## devices (this machine only), holds the look direction and aims the camera arm, owns the player's one arm (it moves to each pawn
## taken), and gives its pawn this tick's input when the ControllerManager asks ([method take_input_command]). Named actions come from
## keys through [member action_keys]. It moves nothing itself: the pawn's abilities do. Click-to-move is a [MoveToStep] on its
## [member step_host], which writes the move while it runs. To drive it from a script, extend it and override the _read functions.
## [br]Spectating ([method start_spectating], a FreeFlyCamera): the player README.
## Design: pawn spec 5, 6.2, 8.18.
# REFACTOR: the InputMap names for moving, the wheel and the mouse buttons (move_left, scrollWheel_up, left_click, middleMouse_button)
# are written in the code, unlike action_keys; settings would let a designer remap them without code. See CHANGELOG.md.
class_name PlayerController
extends ControllerBase

enum LookMode {
	## The mouse is captured and turns the view, as in most action games.
	CAPTURED,
	## The mouse stays free and the view turns when it nears the edge of the screen, as many strategy games do.
	SCREEN_EDGE,
}

## How the mouse turns the view: captured, or turning at the screen's edge.
@export var look_mode := LookMode.CAPTURED
## Radians turned per pixel the mouse moves, in CAPTURED mode.
@export var mouse_sensitivity := 0.0025
## How much of the screen counts as the edge, in SCREEN_EDGE mode, as a share of its width.
@export_range(0.01, 0.5, 0.01) var edge_zone := 0.125
## How fast the view turns at the very edge, in degrees per second, in SCREEN_EDGE mode.
@export var edge_turn_speed := 150.0
## On: clicking the ground walks there, along a nav path ([method move_to]).
@export var click_to_move := false
## Which key in the project's input map presses which named action. The left side is an action from InputActions, and the right is an
## action in Project Settings > Input Map. An action with no key here is never pressed by the player.
# dash is Left Alt and primary the left mouse button (a melee swing).
@export var action_keys: Dictionary[StringName, StringName] = {&"jump": &"move_jump", &"sprint": &"move_sprint", &"dash": &"move_dash", &"primary": &"attack_primary"}
## The free-flying camera used while spectating (start_spectating()). Its root must be a FreeFlyCamera. Empty: a
## FreeFlyCamera with its default settings.
@export var spectator_scene: PackedScene
## The key (InputMap action) that flies the spectator straight up: jump by default, so flying matches walking.
@export var fly_up_key: StringName = &"move_jump"
## The key that flies the spectator straight down: crouch by default.
@export var fly_down_key: StringName = &"move_crouch"

## The real camera. It holds where it is while there's no view to follow.
var camera: PlayerCamera = null
## What the mouse or crosshair points at. It's off until something asks it.
var world_cursor: WorldCursor = null
## Where the player is looking, sideways, in radians.
var look_yaw := 0.0
## Where the player is looking, up and down, in radians.
var look_pitch := 0.0
## Runs the steps that write this controller's input for it: click-to-move's [MoveToStep], named MoveTo. Made when it's ready.
var step_host: ControllerStepHost = null

# Actions pressed since the last tick, as bits, so a tap shorter than a tick still counts.
var _latched_actions := 0
var _zoom_steps := 0.0
var _arm: CameraArm = null
var _own_arm: CameraArm = null # the player's one arm, moved to each pawn they take; made when first needed
var _spectator: FreeFlyCamera = null # made the first time it spectates, and kept
var _spectating := false


func _ready() -> void:
	# It stays out of the scene until it has a view. Godot makes the first camera it sees the active one, and this autoload's
	# child would come before any level's camera, taking over from cameras that don't ask to be current.
	camera = PlayerCamera.new()
	camera.name = "PlayerCamera"
	world_cursor = WorldCursor.new()
	world_cursor.name = "WorldCursor"
	add_child(world_cursor)
	step_host = ControllerStepHost.new()
	step_host.name = "StepHost"
	var move_step := MoveToStep.new()
	move_step.name = "MoveTo"
	step_host.add_child(move_step)
	add_child(step_host)
	step_host.set_pawn(pawn)


func _exit_tree() -> void:
	# It lets go of its pawn's ControllerManager.
	if is_instance_valid(pawn) and pawn.controller_manager:
		pawn.controller_manager.detach_player(self)
	if is_instance_valid(camera) and not camera.is_inside_tree():
		camera.free() # it isn't our child yet, so nothing else would


# --- Called by PossessionCoordinator ---


## Takes this pawn, and lets go of any other. Null means none. Nothing else should call this: ask PossessionCoordinator.
func take_pawn(new_pawn: Pawn) -> void:
	if pawn == new_pawn:
		return
	# A pawn has the keys now, so spectating stops. The pawn's view is set below.
	if new_pawn != null and _spectating:
		stop_spectating()
	_let_go_of_arm()
	# The pawn's ControllerManager asks this controller for input while it's attached.
	if is_instance_valid(pawn) and pawn.controller_manager:
		pawn.controller_manager.detach_player(self)
	pawn = new_pawn
	if step_host:
		step_host.set_pawn(pawn) # a walk left unfinished belonged to the last pawn
	if pawn and pawn.controller_manager:
		pawn.controller_manager.attach_player(self)
	elif pawn:
		push_warning("PlayerController: %s has no ControllerManager, so this controller can't drive it. Check its skip_default_parts." % pawn.name)
	if pawn == null:
		# Unless spectating, which keeps its own view and the mouse (a client's release arrives after it starts).
		if not _spectating:
			camera.set_view(null)
			_show_mouse()
		_latched_actions = 0 # a press before letting go doesn't belong to the next pawn
	else:
		# A pawn's own placed arm or view is used as it is; otherwise the player's one arm moves to the pawn's mount.
		_arm = CameraMount.arm_of(pawn)
		if _arm == null and CameraMount.view_of(pawn) == null:
			_arm = _attach_own_arm(pawn)
		if _arm:
			_arm.set_active(true)
			# The view stays where the player was looking, as far as this arm allows.
			look_pitch = _arm.set_look(look_yaw, look_pitch if _had_pawn else _arm.get_pitch())
		if not camera.is_inside_tree():
			add_child(camera)
		camera.set_view(CameraMount.view_of(pawn))
		_capture_mouse()
		_had_pawn = true
	pawn_changed.emit(pawn)


# --- Spectating ---


## Flies a FreeFlyCamera with the player's keys and mouse, starting where the camera is now. Taking a pawn stops it.
## Games ask PossessionCoordinator.spectate(), which lets go of the pawn first and keeps track; calling this directly is for tests.
func start_spectating() -> void:
	if _spectating:
		return
	if not is_instance_valid(_spectator):
		_spectator = _make_spectator()
	var start := camera.global_position if camera.is_inside_tree() else Vector3.ZERO
	_spectator.begin(start)
	# The view keeps looking where the camera did.
	if camera.is_inside_tree():
		_look_along(-camera.global_basis.z)
	if not camera.is_inside_tree():
		add_child(camera)
	camera.set_view(_spectator.view)
	_spectating = true
	_capture_mouse()


## Stops flying. The camera holds where it is until there's a pawn. Games ask PossessionCoordinator.stop_spectating().
func stop_spectating() -> void:
	if not _spectating:
		return
	_spectating = false
	_spectator.end()
	if not is_instance_valid(pawn):
		camera.set_view(null)
		_show_mouse()


## While spectating, moves the spectator to this place and faces it the same way, as for an overview point. False
## when not spectating, and nothing moves.
func place_spectator(at: Transform3D) -> bool:
	if not _spectating or not is_instance_valid(_spectator):
		return false
	_spectator.teleport(at.origin)
	_look_along(-at.basis.z) # Godot's forward is -Z
	return true


## True while flying a FreeFlyCamera.
func is_spectating() -> bool:
	return _spectating


## The FreeFlyCamera, or null before the first time it spectates. For tests and debug tools.
func get_spectator() -> FreeFlyCamera:
	return _spectator


# --- Input for the pawn ---


## This tick's input, from the devices. It uses up the presses saved since the last tick, so call it once per tick.
func take_input_command(_tick: int) -> InputCommand:
	var command := InputCommand.new()
	var wanted := _read_move()
	# Godot's forward is -Z, and move input's Y is backward, the way Input.get_vector gives it.
	command.move = Basis(Vector3.UP, look_yaw) * Vector3(wanted.x, 0.0, wanted.y)
	# Keys take over from a click: the walk is dropped. While it runs (waiting for nav counts too), its step writes the move, and
	# presses a link's action, such as jump, for the tick the path reaches it.
	var link_press := 0
	if step_host and step_host.is_running():
		if wanted.length_squared() > 0.01:
			step_host.stop()
		else:
			step_host.run(pawn.ticks_elapsed if is_instance_valid(pawn) else 1)
			command.move = step_host.input.move
			link_press = step_host.input.held_actions
	command.look_yaw = look_yaw
	command.look_pitch = look_pitch
	# How far behind this client draws others, so the server judges its swings against what it saw (lag compensation).
	var session: Node = get_node_or_null("/root/NetworkSession")
	command.view_ticks_behind = session.get_view_ticks_behind() if session else 0.0
	# Held now, or pressed and let go again since the last tick.
	command.held_actions = _latched_actions | link_press
	_latched_actions = 0
	for action: StringName in action_keys:
		if _read_action_held(action):
			command.held_actions |= InputActions.mask_of(action)
	# Spectating, the keys fly the spectator, so a pawn still attached (a client waiting for its release) gets none.
	if _spectating:
		command.move = Vector3.ZERO
		command.held_actions = 0
	return command


## Walks the pawn to this place along a nav path, and in a straight line if there's no nav here, by starting its step host's
## MoveTo step. Keys take over from it. False if there's no pawn or there's no way there.
func move_to(world_point: Vector3) -> bool:
	var move_step := _move_step()
	if move_step == null or not is_instance_valid(pawn):
		return false
	move_step.goal = world_point
	if not step_host.start(move_step) or move_step.follower.get_path_state() == PathFollower.PathState.UNREACHABLE:
		step_host.stop()
		return false
	return true


## True while it's walking a path from move_to.
func is_following_path() -> bool:
	var move_step := _move_step()
	return move_step != null and move_step.running and move_step.follower.is_following_path()


## The path follower of the walk it's on, or null when it isn't on one (pawn spec 16.7).
func get_path_follower() -> PathFollower:
	var move_step := _move_step()
	return move_step.follower if move_step and move_step.running else null


## Drops a walk from move_to, if one is under way.
func drop_path() -> void:
	if step_host:
		step_host.stop()


# Click-to-move's step, or null before the host is made.
func _move_step() -> MoveToStep:
	return step_host.get_node_or_null(^"MoveTo") as MoveToStep if step_host else null


# --- Per rendered frame: never changes game state ---


func _process(delta: float) -> void:
	# Presses are kept only with a pawn, so a press with nothing to drive never carries over to the next pawn it gets.
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
	var wheel := _zoom_steps # kept for spectating, below
	if is_instance_valid(_arm):
		look_pitch = _arm.set_look(look_yaw, look_pitch)
		if _zoom_steps != 0.0:
			_arm.zoom(_zoom_steps)
	_zoom_steps = 0.0
	# Spectating. Up and down is as far as straight up and down, a little short so the view never flips.
	if _spectating and is_instance_valid(_spectator):
		look_pitch = clampf(look_pitch, -1.55, 1.55)
		var wanted := _read_move()
		var fast := _read_action_held(&"sprint")
		# With sprint held, the wheel speeds the fast flying up (wheel up) or down; on its own it zooms (wheel up is in). The zoom
		# steps count wheel up as -1.
		if wheel != 0.0:
			if fast:
				_spectator.change_fast_speed(-wheel)
			else:
				_spectator.change_zoom(-wheel)
		_spectator.fly(Vector3(wanted.x, _read_fly_up_down(), wanted.y), fast, look_yaw, look_pitch, delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and look_mode == LookMode.CAPTURED and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Zoomed in while spectating, the mouse turns slower by as much, so aiming feels the same.
		var sensitivity := mouse_sensitivity / (_spectator.get_zoom() if _spectating and is_instance_valid(_spectator) else 1.0)
		look_yaw = wrapf(look_yaw - event.relative.x * sensitivity, -PI, PI)
		look_pitch -= event.relative.y * sensitivity
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
			move_to(hit["position"]) # a click with no way there does nothing, rather than walking straight at it
	elif _spectating and is_instance_valid(_spectator) and InputMap.has_action(&"middleMouse_button") and event.is_action_pressed(&"middleMouse_button"):
		_spectator.reset_zoom() # spectating, the middle mouse button resets the zoom
		_capture_mouse()
	elif event is InputEventMouseButton and event.pressed and (is_instance_valid(pawn) or _spectating):
		_capture_mouse()


# --- Reading devices. Override these to drive it from a script. ---


## Which way to go, with X to the right and Y backward, up to length 1.
func _read_move() -> Vector2:
	if not _has_actions([&"move_left", &"move_right", &"move_forward", &"move_backward"]):
		return Vector2.ZERO
	return Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")


## True while the key for this named action is down.
func _read_action_held(action: StringName) -> bool:
	var key: StringName = action_keys.get(action, &"")
	return key != &"" and InputMap.has_action(key) and Input.is_action_pressed(key)


## True on the rendered frame the key for this named action went down.
func _read_action_pressed(action: StringName) -> bool:
	var key: StringName = action_keys.get(action, &"")
	return key != &"" and InputMap.has_action(key) and Input.is_action_just_pressed(key)


## Spectating: up (1) or down (-1), from fly_up_key and fly_down_key (Space and Ctrl by default), so flying matches walking.
func _read_fly_up_down() -> float:
	if not _has_actions([fly_up_key, fly_down_key]):
		return 0.0
	return Input.get_action_strength(fly_up_key) - Input.get_action_strength(fly_down_key)


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


## SCREEN_EDGE turning: faster the closer the mouse is to the edge.
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
		# The player's own arm comes back here, idle, for the next pawn. A placed arm stays on its pawn.
		if _arm == _own_arm and _arm.get_parent() != self:
			_arm.reparent(self, false)
	_arm = null


# Moves the player's arm to a pawn's mount (its CameraMount, or Visual), with the pawn's preset, ignoring the pawn's own body.
func _attach_own_arm(target: Pawn) -> CameraArm:
	if not is_instance_valid(_own_arm):
		_own_arm = CameraArm.new()
		_own_arm.name = "CameraArm"
		add_child(_own_arm)
	_own_arm.reparent(CameraMount.mount_of(target), false)
	_own_arm.apply_preset(CameraMount.preset_of(target))
	_own_arm.clear_ignored()
	_own_arm.ignore_body(target)
	return _own_arm


# Sets the look to face along this direction. Yaw 0 faces -Z, Godot's forward.
func _look_along(forward: Vector3) -> void:
	look_yaw = atan2(-forward.x, -forward.z)
	look_pitch = asin(clampf(forward.normalized().y, -1.0, 1.0))


# The spectator, from spectator_scene, or a default FreeFlyCamera. A child of this controller, so it lasts as long as it.
func _make_spectator() -> FreeFlyCamera:
	var made: FreeFlyCamera = null
	if spectator_scene:
		var node := spectator_scene.instantiate()
		made = node as FreeFlyCamera
		if made == null:
			push_warning("PlayerController: spectator_scene's root isn't a FreeFlyCamera, so this uses the default.")
			node.free()
	if made == null:
		made = FreeFlyCamera.new()
	made.name = "Spectator"
	add_child(made)
	return made


func _capture_mouse() -> void:
	if look_mode == LookMode.CAPTURED and not click_to_move:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _show_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
