# Written by Claude (claude-opus-5-5), 2026-11-12. History: visuals/CHANGELOG.md.
## Makes a pawn's model move like a toy being played with: rocking, hopping, leaning into a dash and falling over when it dies.
##
## Part of the toy look (pawn spec 8.12). Put it under the pawn's Visual/Model; it makes the model from [member toy_scene] (held in
## the first frame of [member pose_animation]) and stands it on a coloured base so teams can be told apart. It moves only itself, with
## its origin at the pawn's feet, so "forward" is the pawn's -Z. The waddle's speed comes from how fast the drawn model moves, not the
## pawn's velocity, so pawns drawn from snapshots on a client waddle too.
## [br]
## Visual only: once per rendered frame, only reads the pawn, changes nothing simulated, so it needs no rollback. With no display it
## builds nothing and never runs (RunEnvironment.runs_visuals).
class_name ToyWaddle
extends Node3D

## The model to show, such as a Kenney character's .glb. Empty: nothing is made, and this only moves whatever children it already has.
@export var toy_scene: PackedScene
## How much bigger the model is drawn. Kenney's mini characters are about 0.8 m tall; 2.2 makes them about the height of the pawn's
## 1.8 m capsule.
@export_range(0.1, 10.0, 0.05, "or_greater") var toy_scale := 2.2
## On: the model is turned round 180 degrees, for a model that faces +Z, as Kenney's characters do (glTF's front is +Z). The pawn's
## forward is -Z.
@export var turn_model_round := true
## The animation whose first frame holds the model still, if it has an AnimationPlayer with one. Kenney's characters have "idle",
## whose first frame has the arms down ("static" holds them straight out).
@export var pose_animation: StringName = &"idle"
## The colour of the round base the figure stands on, like a toy figurine's. Fully clear (alpha 0): no base.
@export var stand_color := Color(0.9, 0.75, 0.3, 1.0)
## The base's radius, in metres.
@export_range(0.05, 3.0, 0.01, "or_greater") var stand_radius := 0.45

@export_group("Waddle")
## How far it rocks from side to side at full walking speed, in degrees each way.
@export_range(0.0, 45.0, 0.5) var rock_degrees := 10.0
## How high each step's little hop is at full walking speed, in metres.
@export_range(0.0, 1.0, 0.01) var hop_height := 0.09
## Steps per metre walked. Each step is one rock to a side and one hop.
@export_range(0.1, 10.0, 0.1, "or_greater") var steps_per_metre := 1.6
## How far it leans forward while moving at full walking speed, in degrees.
@export_range(0.0, 45.0, 0.5) var lean_degrees := 6.0
## The speed counted as full walking speed, in metres per second, for the amounts above. Faster (sprinting) rocks and hops a little
## more, up to one and a half times.
@export_range(0.1, 20.0, 0.1, "or_greater") var walk_speed := 5.0
## Standing still: how far it bobs up and down, in metres, and how many times a second.
@export_range(0.0, 0.2, 0.005) var breathe_height := 0.015
@export_range(0.0, 5.0, 0.05) var breathe_rate := 0.8

@export_group("Moments")
## While dashing: how far it leans forward, in degrees.
@export_range(0.0, 80.0, 0.5) var dash_lean_degrees := 28.0
## While being knocked back: how far it tips backward, in degrees.
@export_range(0.0, 80.0, 0.5) var knockback_tilt_degrees := 22.0
## While off the ground: how far it tilts back, in degrees.
@export_range(0.0, 45.0, 0.5) var air_tilt_degrees := 8.0
## When it dies: how far it falls over onto its side, in degrees (90 is flat), and how fast it settles there.
@export_range(0.0, 120.0, 1.0) var death_fall_degrees := 90.0
## How quickly it eases toward a new lean or tilt: higher is snappier. Each frame it closes this fraction of the gap per second,
## roughly; 12 settles in about a quarter of a second.
@export_range(0.5, 60.0, 0.5, "or_greater") var ease_rate := 12.0

var _pawn: Pawn = null
var _visual: Node3D = null
var _bound := false
var _toy: Node3D = null
var _dash: AbilityBase = null
var _knockback: AbilityBase = null
var _last_position := Vector3.ZERO
var _speed := 0.0 # metres per second the drawn model moves, smoothed
var _step_phase := 0.0 # in radians: one step is half a turn
var _breath_phase := 0.0
var _lean := 0.0 # radians, forward is negative (see _animate)
var _fall := 0.0 # radians, toward the pawn's right side


func _ready() -> void:
	# Nothing to draw on, so nothing to build or move (see the class description).
	if not RunEnvironment.runs_visuals():
		set_process(false)
		return
	_pawn = _find_pawn()
	if toy_scene:
		_toy = toy_scene.instantiate() as Node3D
		if _toy:
			_toy.scale = Vector3.ONE * toy_scale
			if turn_model_round:
				_toy.rotation.y = PI
			add_child(_toy)
			_hold_pose(_toy)
	if stand_color.a > 0.0:
		add_child(_make_stand())


# The pawn's Visual and abilities, found on the first frame. Not in _ready: a pawn finds its own parts in its _ready, which Godot runs
# after its children's, this one included.
func _bind() -> void:
	_bound = true
	_visual = _pawn.get_visual()
	# "is" checks the class, so a scene's own Dash subclass counts.
	if _pawn.ability_manager:
		for ability in _pawn.ability_manager.get_abilities():
			if ability is DashAbility and _dash == null:
				_dash = ability
			elif ability is KnockbackAbility and _knockback == null:
				_knockback = ability
	_last_position = _visual.global_position


func _process(delta: float) -> void:
	var started := PerfScopes.begin() # timed for diagnostics, in its animation category
	_animate(delta)
	PerfScopes.end(&"animation.waddle", started)


# The work itself, timed by _process.
func _animate(delta: float) -> void:
	if _pawn == null or delta <= 0.0:
		return
	if not _bound:
		_bind()
	# How fast the drawn model moves along the ground, smoothed so a correction's jump doesn't make it hop wildly.
	var at := _visual.global_position
	var moved := at - _last_position
	moved.y = 0.0
	_last_position = at
	# Named blend, not ease, which is one of Godot's own functions.
	var blend := 1.0 - exp(-ease_rate * delta) # the same easing at any frame rate
	_speed = lerpf(_speed, moved.length() / delta, blend)
	var dead := _pawn.is_dead()
	var amount := 0.0 if dead else clampf(_speed / walk_speed, 0.0, 1.5) # 0 standing, 1 walking, up to 1.5 sprinting

	# Steps: the phase moves on with distance, so a step always covers the same ground, whatever the speed.
	_step_phase = fmod(_step_phase + _speed * delta * steps_per_metre * PI, TAU)
	_breath_phase = fmod(_breath_phase + delta * breathe_rate * TAU, TAU)
	var rock := sin(_step_phase) * deg_to_rad(rock_degrees) * minf(amount, 1.5)
	var hop := absf(sin(_step_phase)) * hop_height * minf(amount, 1.5)
	var breathe := (sin(_breath_phase) * 0.5 + 0.5) * breathe_height * clampf(1.0 - amount * 2.0, 0.0, 1.0)

	# Leaning: forward (top toward -Z) is a negative turn about X, backward positive. The strongest moment wins.
	var lean_target := -deg_to_rad(lean_degrees) * minf(amount, 1.0)
	if not _pawn.grounded:
		lean_target = deg_to_rad(air_tilt_degrees)
	if _knockback and _knockback.is_running_timed():
		lean_target = deg_to_rad(knockback_tilt_degrees)
	if _dash and _dash.is_running_timed():
		lean_target = -deg_to_rad(dash_lean_degrees)
	if dead:
		lean_target = 0.0
	_lean = lerpf(_lean, lean_target, blend)
	# Falling over when it dies, and standing back up when revived. Slower than a lean, like a toy toppling.
	_fall = lerpf(_fall, deg_to_rad(death_fall_degrees) if dead else 0.0, 1.0 - exp(-ease_rate * 0.5 * delta))

	position = Vector3(0.0, hop + breathe, 0.0)
	# Radians, x then y then z: z turns it to its side (rocking, falling), x tips it forward or back.
	rotation = Vector3(_lean, 0.0, -(rock + _fall))


# The pawn this belongs to: the nearest Pawn above it.
# REFACTOR: the same search, and the same find-the-parts-on-the-first-frame pattern, is in FloatingSword; a small shared base for
# per-frame pawn visuals would hold it once (duplicated logic). See CHANGELOG.md.
func _find_pawn() -> Pawn:
	var at := get_parent()
	while at and not at is Pawn:
		at = at.get_parent()
	return at as Pawn


# Holds the first frame of pose_animation on the model's AnimationPlayer, if it has one, so the model keeps a still pose.
func _hold_pose(model: Node) -> void:
	if pose_animation == &"":
		return
	for player: AnimationPlayer in model.find_children("*", "AnimationPlayer", true, false):
		if player.has_animation(pose_animation):
			# play() then pause() at the start shows that frame and leaves it there.
			player.play(pose_animation)
			player.seek(0.0, true)
			player.pause()


# A thin disc under the feet, in stand_color: the figurine's base.
func _make_stand() -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = stand_radius
	mesh.bottom_radius = stand_radius * 1.08
	mesh.height = 0.06
	mesh.radial_segments = 20
	var material := StandardMaterial3D.new()
	material.albedo_color = stand_color
	mesh.material = material
	var stand := MeshInstance3D.new()
	stand.name = "Stand"
	stand.mesh = mesh
	stand.position.y = 0.03
	stand.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return stand
