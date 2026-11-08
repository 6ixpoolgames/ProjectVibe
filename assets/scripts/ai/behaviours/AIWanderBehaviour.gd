## Written by Claude (claude-opus-5-5), 2026-11-09: walks to random nearby points, pausing between them. Pawn spec section 10.7.
## Allowed in Idle by default. Step 8a's behaviour, to prove deciding and acting with no senses.
##
## What it does, over and over: picks a random point within wander_radius of its home (where the pawn was when it first started
## wandering), walks there with the AI controller's move_to, so it follows nav paths and crosses links, then stands for a random
## time between min_pause_ticks and max_pause_ticks.
##
## The random points and pauses come from the context's replayable random numbers, so the same seed, pawn and ticks give the same
## walk. A point with no way there is skipped, and another is tried on the next tick.
##
## It never finishes on its own (it returns RUNNING), so it runs until something better comes along.
class_name AIWanderBehaviour
extends AIBehaviourBase

## How far from home it wanders, in metres.
@export_range(0.5, 200.0, 0.5, "or_greater") var wander_radius := 8.0
## The shortest stand between walks, in ticks.
@export_range(0, 36000, 1, "or_greater") var min_pause_ticks := 30
## The longest stand between walks, in ticks.
@export_range(0, 36000, 1, "or_greater") var max_pause_ticks := 120

const POINT_ANGLE_SALT := 0x51A1 # what each random number is for, so they differ from each other
const POINT_DISTANCE_SALT := 0x51A2
const PAUSE_SALT := 0x51A3

var _home := Vector3.ZERO
var _has_home := false
var _walking := false # a walk was started and hasn't been seen to end
var _pause_left := 0


func _init() -> void:
	super()
	allowed_states = [&"Idle"]
	# GDScript note: a low, fixed score: Wander is what a pawn does when nothing more interesting can run.
	max_score = 0.1
	min_score = 0.1


func enter(_context: AIContextComponent) -> void:
	if not _has_home and pawn:
		_home = pawn.global_position
		_has_home = true
	_walking = false
	_pause_left = 0


func tick(context: AIContextComponent) -> Status:
	var hands := context.controller
	if hands == null or pawn == null:
		return Status.FAILED
	if _pause_left > 0:
		_pause_left -= 1
		return Status.RUNNING
	if hands.is_following_order():
		return Status.RUNNING
	if _walking:
		# The walk ended: it arrived, or nav gave up on it. Stand for a while either way.
		_walking = false
		_pause_left = min_pause_ticks + int(context.random_unit(PAUSE_SALT) * (maxi(max_pause_ticks - min_pause_ticks, 0) + 1))
		return Status.RUNNING
	# GDScript note: sqrt makes points spread evenly over the circle; without it they'd bunch up near the middle.
	var angle := context.random_unit(POINT_ANGLE_SALT) * TAU
	var distance := sqrt(context.random_unit(POINT_DISTANCE_SALT)) * wander_radius
	var point := _home + Vector3(cos(angle), 0.0, sin(angle)) * distance
	if hands.move_to(point):
		_walking = true
	return Status.RUNNING


func exit(context: AIContextComponent, _reason: String) -> void:
	_walking = false
	_pause_left = 0
	if context and context.controller:
		context.controller.stop()
