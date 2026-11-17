# Written by Claude (claude-opus-5-5), 2026-11-16. History: camera/CHANGELOG.md.
## A camera that flies freely, for a player with no pawn: the spectator.
##
## For the spectator view between matches, while waiting to respawn, or after letting go of a pawn. PossessionCoordinator.spectate()
## starts it: the PlayerController makes one the first time and flies it with the player's keys and mouse.
## [br]
## It isn't a Pawn. A Pawn is a whole character: it's simulated on ticks, rolled back, networked, recorded in replays, counted on a
## team, seen by the AI and killed by the kill floor. A spectator needs none of that. Unreal does the same: its PlayerController spawns
## its spectator on its own machine only, and nothing else in the game knows it's there. So it's local and per rendered frame, like
## the camera arm: never ticked, never sent over the network, never rolled back.
## [br]
## What it carries:
## [br]- View: a VirtualCamera, which the PlayerController's real camera follows while spectating.
## [br]- StreamingSource: keeps the world loaded around it while it's flying ([member keeps_world_loaded]), so flying away from every
##   pawn still shows ground. On a client it loads only that client's world, as any camera's source does.
## [br]
## How to use it: nothing to set up for the default. A game wanting different settings or a model for its spectator makes a scene
## whose root is a FreeFlyCamera and sets it as the PlayerController's spectator_scene.
## [br]
## Controls (read by the PlayerController): WASD flies where the view looks, Space and Ctrl go straight up and down (the jump and
## crouch keys, the PlayerController's fly_up_key and fly_down_key), and the mouse looks. 10 m/s, 25 with the sprint key held, and
## with it held the wheel ramps that fast speed up or down, up to 75. The wheel on its own zooms, by narrowing the field of view as a
## lens does, so it stays where it is; the mouse turns slower to match. The middle mouse button (middleMouse_button) resets the zoom.
## [br]
## It goes through ground and walls: there's no collision.
class_name FreeFlyCamera
extends Node3D

## How fast it flies, in metres per second.
@export var speed := 10.0
## How fast it flies with the sprint key held, in metres per second, to start with. The wheel changes it while sprint is held.
@export var fast_speed := 25.0
## The most the wheel can raise the fast speed to, in metres per second. The least is speed.
@export var max_fast_speed := 75.0
## How much one notch of the wheel changes the fast speed, in metres per second.
@export var fast_speed_step := 5.0
## How much one notch of the wheel zooms in or out, as a multiple: 1.25 makes things look 1.25 times bigger.
@export var zoom_per_notch := 1.25
## The most it zooms in, as a multiple of how big things look at fov.
@export var max_zoom := 8.0
## How long it takes to reach full speed from standing, or to stop, in seconds. 0 is at once.
@export var seconds_to_full_speed := 0.15
## The field of view while it's the view, in degrees.
@export_range(1.0, 179.0, 0.1) var fov := 75.0
## On: it keeps the world loaded around it while it's flying, through its StreamingSource. It can be changed while
## flying (the mass battle turns it off, so its own sources decide what's loaded).
## GDScript note: set(value) runs whenever the value is assigned, so the source follows at once.
@export var keeps_world_loaded := true:
	set(value):
		keeps_world_loaded = value
		if streaming_source:
			streaming_source.active = _flying and value

## Where the real camera goes. Made here if the scene doesn't have one called View.
var view: VirtualCamera = null
## The source that keeps the world loaded around it. Made here if the scene doesn't have one called StreamingSource.
var streaming_source: StreamingSource = null

var _velocity := Vector3.ZERO
var _flying := false
var _fast_speed := -1.0 # the fast speed now, after the wheel; -1 until first used, then fast_speed
var _zoom := 1.0 # 1 is no zoom


## How zoomed in it is: 1 is none, 2 makes things look twice as big.
func get_zoom() -> float:
	return _zoom


## Zooms by this many notches of the wheel (in is positive), between none and max_zoom.
func change_zoom(notches: float) -> void:
	_zoom = clampf(_zoom * pow(zoom_per_notch, notches), 1.0, max_zoom)
	_apply_zoom()


## The fast speed now, in metres per second: fast_speed, as the wheel has changed it.
func get_fast_speed() -> float:
	return fast_speed if _fast_speed < 0.0 else _fast_speed


## Changes the fast speed by this many notches of the wheel (up is positive), between speed and max_fast_speed.
func change_fast_speed(notches: float) -> void:
	_fast_speed = clampf(get_fast_speed() + notches * fast_speed_step, speed, max_fast_speed)


func _init() -> void:
	# GDScript note: it moves only when the PlayerController calls fly(), once a rendered frame, so it needs no _process of its own.
	set_process(false)
	set_physics_process(false)


func _ready() -> void:
	# GDScript note: "as" gives null when the node is missing or of another type, so a scene that leaves either out still works.
	view = get_node_or_null(^"View") as VirtualCamera
	if view == null:
		view = VirtualCamera.new()
		view.name = "View"
		add_child(view)
	_apply_zoom() # sets view.fov for the zoom
	streaming_source = get_node_or_null(^"StreamingSource") as StreamingSource
	if streaming_source == null:
		streaming_source = StreamingSource.new()
		streaming_source.name = "StreamingSource"
		add_child(streaming_source)
	streaming_source.active = _flying and keeps_world_loaded


## Starts flying from this place, standing still. The PlayerController passes where its camera is, so the view doesn't jump.
func begin(at: Vector3) -> void:
	global_position = at
	_velocity = Vector3.ZERO
	_flying = true
	_zoom = 1.0 # each time it starts, unzoomed
	_apply_zoom()
	if streaming_source:
		streaming_source.active = keeps_world_loaded


## Stops flying. It stays where it is, and no longer keeps the world loaded.
func end() -> void:
	_flying = false
	_velocity = Vector3.ZERO
	if streaming_source:
		streaming_source.active = false


## True between begin() and end().
func is_flying() -> bool:
	return _flying


## Jumps to this place and stops there, as for an overview point. Which way it faces is the player's look, which
## the PlayerController sets (PlayerController.place_spectator()).
func teleport(to: Vector3) -> void:
	global_position = to
	_velocity = Vector3.ZERO


## Back to no zoom (the middle mouse button).
func reset_zoom() -> void:
	_zoom = 1.0
	_apply_zoom()


# The view's field of view for the zoom. Zooming by 2 halves the width of what's seen, so the angle's tangent halves.
func _apply_zoom() -> void:
	if view:
		view.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(fov) / 2.0) / _zoom))


## Moves it for one rendered frame. wish: x to the right, y up, z backward, each from -1 to 1, the way the keys give them. yaw and pitch
## are the player's look, in radians, and the view faces that way.
func fly(wish: Vector3, fast: bool, yaw: float, pitch: float, delta: float) -> void:
	if not _flying:
		return
	# GDScript note: a Node3D's rotation turns around Y (yaw) first and then X (pitch), so this faces where the player looks.
	rotation = Vector3(pitch, yaw, 0.0)
	# Forward and sideways follow the view, pitch included, so looking down and pressing W flies down. Up and down are straight up and down.
	var along_view := global_basis * Vector3(wish.x, 0.0, wish.z)
	var direction := (along_view + Vector3.UP * wish.y).limit_length(1.0)
	var top_speed := get_fast_speed() if fast else speed
	var wanted := direction * top_speed
	if seconds_to_full_speed <= 0.0:
		_velocity = wanted
	else:
		# GDScript note: move_toward changes the velocity by at most this much, so speeding up and slowing down take the same time.
		_velocity = _velocity.move_toward(wanted, top_speed / seconds_to_full_speed * delta)
	global_position += _velocity * delta
