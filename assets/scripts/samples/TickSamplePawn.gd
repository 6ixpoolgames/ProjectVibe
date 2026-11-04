## Written by Claude (claude-opus-5-5), 2026-11-04: sample pawn showing how to hook gameplay onto the tick driver (NetworkTime).
## A teaching example, deliberately all in one script. The real pawn splits these jobs across the controller,
## abilities (Walk, Jump) and the motor (pawn spec), but the tick pattern is exactly this.
##
## What it shows:
##   - registering with NetworkTime, and an escape clause when the autoload is missing
##   - _tick_input: deciding what the pawn WANTS this tick (player keys, or a seeded random wander), as plain data
##   - _tick_simulate: acting on it with the fixed tick dt (steer, turn, gravity, jump, move_and_slide)
##   - _tick_record: saving the state rollback will need later (here into a small ring buffer)
##   - timers in ticks, seconds only in the inspector
##   - latching a key press between rendered frames and ticks, so a press is never lost or doubled
##   - smoothing the visible model between ticks with the interpolation fraction
extends CharacterBody3D
class_name TickSamplePawn

enum Brain { PLAYER, WANDER, IDLE }

@export var brain: Brain = Brain.WANDER
@export var body_color: Color = Color(0.85, 0.3, 0.3)
@export_group("Movement")
@export var max_speed: float = 5.0
@export var sprint_multiplier: float = 1.8
@export var acceleration: float = 30.0
@export var deceleration: float = 40.0
@export var turn_rate_deg: float = 720.0
@export var jump_velocity: float = 5.0
@export_group("Wander")
## Seconds between wander decisions; converted to ticks.
@export var wander_change_seconds: float = 1.5
@export_group("Visuals")
## Blend the visible model between ticks. Turn off to see the raw tick steps (most visible at low tick rates).
@export var smooth_visuals: bool = true
@export var model_path: NodePath = ^"Model"

# This tick's input command: what the pawn wants. Plain data, so it could later be sent over the network.
var move_dir := Vector3.ZERO
var wants_sprint := false
var wants_jump := false

const HISTORY_SIZE := 64

var _driver: Node = null         # the NetworkTime autoload, or null (escape clause: we tick ourselves)
var _fallback_tick := 0
var _jump_latched := false       # set per rendered frame, consumed by the next tick
var _rng := RandomNumberGenerator.new()
var _next_wander_tick := 0
var _model: Node3D = null
var _model_offset := Transform3D.IDENTITY
var _prev_xform := Transform3D.IDENTITY # body transform before and after the last tick, for smoothing
var _curr_xform := Transform3D.IDENTITY
var _history: Array = []
var _gravity: float = 9.8


func _enter_tree() -> void:
	add_to_group(&"tick_sample_pawns") # so the sample HUD can find us
	_driver = get_node_or_null("/root/NetworkTime")
	if _driver:
		_driver.register(self)
	else:
		push_warning("[TickSamplePawn] no NetworkTime autoload; ticking from _physics_process instead")


func _exit_tree() -> void:
	if _driver:
		_driver.unregister(self)


func _ready() -> void:
	# The driver calls us, so our own physics callback stays off. This must be in _ready, not _enter_tree:
	# Godot switches _physics_process on at ready for any script that defines it, which would tick us twice.
	set_physics_process(_driver == null)
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	_rng.seed = hash(String(name)) # seeded: the same pawn wanders the same way on every machine
	_history.resize(HISTORY_SIZE)
	_model = get_node_or_null(model_path)
	if _model:
		_model_offset = _model.transform
		_model.top_level = true # the model is placed by _process, between ticks, not by the body
		_apply_color()
	_prev_xform = global_transform
	_curr_xform = global_transform


# --- Phase 1: input -------------------------------------------------------------------------------

func _tick_input(_dt: float, tick: int) -> void:
	match brain:
		Brain.PLAYER:
			var v := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
			move_dir = _camera_relative(v)
			wants_sprint = Input.is_action_pressed(&"move_sprint")
			wants_jump = _jump_latched
			_jump_latched = false
		Brain.WANDER:
			if tick >= _next_wander_tick:
				var angle := _rng.randf() * TAU
				var walking := _rng.randf() > 0.25 # sometimes stand still for a while
				move_dir = Vector3(cos(angle), 0.0, sin(angle)) if walking else Vector3.ZERO
				_next_wander_tick = tick + _seconds_to_ticks(wander_change_seconds)
			wants_sprint = false
			wants_jump = false
		Brain.IDLE:
			move_dir = Vector3.ZERO
			wants_sprint = false
			wants_jump = false


# --- Phase 2: simulate ----------------------------------------------------------------------------

func _tick_simulate(dt: float, _tick: int) -> void:
	_prev_xform = global_transform

	# Steer: accelerate the horizontal velocity toward what we want (Walk's job in the real pawn).
	var speed := max_speed * (sprint_multiplier if wants_sprint else 1.0)
	var target := move_dir.limit_length(1.0) * speed
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var rate := acceleration if target.length_squared() > 0.0001 else deceleration
	horizontal = horizontal.move_toward(target, rate * dt)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	# Gravity and jump (the motor's and Jump's jobs).
	if not is_on_floor():
		velocity.y -= _gravity * dt
	elif wants_jump:
		velocity.y = jump_velocity
	wants_jump = false

	# Face where we're moving. Godot's forward is -Z.
	if horizontal.length_squared() > 0.01:
		var target_yaw := atan2(-horizontal.x, -horizontal.z)
		rotation.y = rotate_toward(rotation.y, target_yaw, deg_to_rad(turn_rate_deg) * dt)

	# move_and_slide uses Godot's physics delta; scale so one tick moves velocity * tick dt.
	var factor: float = _driver.get_physics_factor() if _driver else 1.0
	velocity *= factor
	move_and_slide()
	velocity /= factor

	_curr_xform = global_transform


# --- Phase 3: record ------------------------------------------------------------------------------

## What rollback will need to restore this tick later (netcode spec section 5.2). For now just stored.
func _tick_record(tick: int) -> void:
	_history[tick % HISTORY_SIZE] = {
		"tick": tick,
		"position": global_position,
		"yaw": rotation.y,
		"velocity": velocity,
		"next_wander_tick": _next_wander_tick,
	}


## The state recorded for a tick, or an empty Dictionary if it's no longer in the history.
func get_recorded(tick: int) -> Dictionary:
	var entry = _history[tick % HISTORY_SIZE]
	return entry if entry is Dictionary and entry.tick == tick else {}


# --- Per rendered frame: presses and visuals ------------------------------------------------------

func _process(_delta: float) -> void:
	# A press lasts one rendered frame. Ticks may run zero or several times per frame, so remember the
	# press until the next tick takes it, instead of reading is_action_just_pressed inside the tick.
	if brain == Brain.PLAYER and Input.is_action_just_pressed(&"move_jump"):
		_jump_latched = true

	if _model:
		var f: float = 1.0
		if smooth_visuals and _driver:
			f = _driver.get_interpolation_fraction()
		_model.global_transform = _prev_xform.interpolate_with(_curr_xform, f) * _model_offset


# --- Escape clause: no tick driver ----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_fallback_tick += 1
	_tick_input(delta, _fallback_tick)
	_tick_simulate(delta, _fallback_tick)
	_tick_record(_fallback_tick)


# --- Helpers ----------------------------------------------------------------------------------------

func _seconds_to_ticks(seconds: float) -> int:
	if _driver:
		return _driver.seconds_to_ticks(seconds)
	return maxi(1, ceili(seconds * Engine.physics_ticks_per_second))


## Turns stick/WASD input into a world direction relative to the camera's facing (flattened).
func _camera_relative(v: Vector2) -> Vector3:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return Vector3(v.x, 0.0, v.y)
	var forward := -cam.global_basis.z
	forward.y = 0.0
	var right := cam.global_basis.x
	right.y = 0.0
	return right.normalized() * v.x + forward.normalized() * -v.y


func _apply_color() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = body_color
	for child in _model.find_children("*", "MeshInstance3D", true, false):
		child.material_override = mat
