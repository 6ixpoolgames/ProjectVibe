# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## A melee swing: an action bound to &"primary", built from steps.
##
## Pawn spec sections 8.6, 8.9 and 8.20. A swing is a WindupStep, which starts a TurnToFaceStep, then a MeleeSweepStep (the hit
## window), then an OpenComboStep and a WaitStep for the recovery. With no AbilityStep children of its own, it makes those from its
## settings below ([member windup_ticks], [member hit_ticks], [member recovery_ticks], [member attack_range], [member hit_radius],
## [member hit_height], [member sweep_degrees], [member sweep_from_left], the two heights,
## [member windup_turn_degrees_per_second], [member combo_window_ticks]): about 0.4 s in all with the defaults. A designer wanting
## another pattern places steps of their own instead, and these settings then only matter for attack_range (the AI's reach) and
## [member warns_targets].
## [br]
## While it runs, all movement and other combat abilities are locked out. Dash (priority 40) cancels it, which is the player's
## animation cancel; Sprint (10) and Jump (5) don't, because its interrupt_threshold is 15. Knockback (30) staggers it.
## [br]
## Turning (the owner's calls): it never snaps to where the pawn looks. Its TurnToFace step turns toward the look, at the pawn's
## TurnRate stat by default, only while the attack's action is held, and keeps turning through the hit while it is. Let go, and it
## swings where it faces. The AI holds its attack action through its swings for this. The windup's timer only counts once the pawn is
## within 90 degrees of where it looks (or the turn has stopped), so a swing started facing away turns first and hits later.
## [br]
## Hits, on the server only (or offline), during the sweep: MeleeSweepStep has the rules (lag compensation, each pawn once per swing,
## its own team skipped). [member attack_range] is the attack's real reach: the AI's Attack behaviour steps in to attack_range minus
## its approach_margin before swinging. A swing carries no damage or knockback of its own: its EffectApplier children say what a hit
## does (on hit, to the target: a StatChangePart for damage, a KnockbackPart for the push and hop), and the target applies them. The
## default swing's are in resources/effects/swing_hit.tres (20 damage, 6 m/s for 10 ticks, a 2 m/s hop). A swing with no on-hit
## effects hits and does nothing, and warns once. A rollback replay never hits again.
## [br]
## The sweep can rise or fall (height_at_sweep_start and _end), for slashes, backhands and chops, and visuals/FloatingSword draws a
## sword through the same spots ([method hit_offset_at]).
class_name MeleeAttackAbility
extends AbilityBase

## Sent on the server for each pawn this swing hits, when the swing finds it. For effects, sounds and UI. The target takes the hit
## (its effects and hit_received) later in the same tick, after every pawn has simulated (pawn spec 15.4).
@warning_ignore("unused_signal") # sent by its MeleeSweepStep
signal hit_landed(hit: HitInfo)
## Sent once per sweep, on its first tick, with where the hit sphere is and its radius. Sent on every machine that runs the swing
## (the server, offline, and a client predicting its own pawn), never during a rollback replay. For effects, sounds and debug drawing
## (AbilityDebugDraw). It says where the swing can hit, not whether it hit anything: see hit_landed.
@warning_ignore("unused_signal") # sent by its MeleeSweepStep
signal hit_window_started(centre: Vector3, radius: float)
## Sent on every tick of a sweep, on the same machines as hit_window_started, with where the hit sphere was at the start and the end
## of this tick's part of the sweep. For effects and debug drawing (AbilityDebugDraw draws the sweep with it).
@warning_ignore("unused_signal") # sent by its MeleeSweepStep
signal hit_area_moved(from: Vector3, to: Vector3, radius: float)

## Ticks from the start of the swing to when it can hit (its Windup step's length).
@export_range(0, 120, 1, "or_greater") var windup_ticks := 8
## Ticks it can hit for (its Sweep step's length).
@export_range(1, 120, 1, "or_greater") var hit_ticks := 4
## Ticks after hitting before it's over (its Recovery step's length).
@export_range(0, 120, 1, "or_greater") var recovery_ticks := 12
## How far it reaches, in metres from the pawn: the far edge of the hit sphere.
@export_range(0.1, 20.0, 0.05, "or_greater") var attack_range := 1.8
## The hit sphere's radius, in metres.
@export_range(0.05, 10.0, 0.05, "or_greater") var hit_radius := 0.8
## The hit sphere's height above the pawn's feet, in metres: about the chest.
@export var hit_height := 1.0
## On: it can hit pawns on its own team.
@export var hits_own_team := false
## How far round the hit sphere sweeps during the hit ticks, in degrees, centred straight ahead. 0: it holds still.
@export_range(0.0, 360.0, 1.0) var sweep_degrees := 100.0
## On: the sweep goes from the pawn's left to its right. Off (the default): right to left.
@export var sweep_from_left := false
## How far above or below hit_height the hit sphere is at the start of the sweep, in metres, so a swing can slash downward, rise, or
## chop straight down (a small sweep_degrees with a big drop). 0 (the default): level. The owner's request, so the floating sword
## (visuals/FloatingSword) can swing high and low and still show exactly where the hit is.
@export_range(-3.0, 3.0, 0.05, "or_greater", "or_less") var height_at_sweep_start := 0.0
## The same at the end of the sweep. Between the two the sphere moves in a straight line up or down.
@export_range(-3.0, 3.0, 0.05, "or_greater", "or_less") var height_at_sweep_end := 0.0
## How fast it turns toward where the pawn looks, in degrees per second: its TurnToFace step's speed. -1 (the default): the pawn's
## TurnRate stat (540 without one), so a turn speed limits every attack the same way. 0: no turning. Above 0: this speed, for this
## attack only.
@export_range(-1.0, 3600.0, 10.0, "or_greater") var windup_turn_degrees_per_second := -1.0
## How long the combo window stays open after its hit, in ticks at 60 a second (its OpenCombo step). Follow-ups are other abilities
## with combo_positions 2 or 3.
@export_range(1, 600, 1, "or_greater") var combo_window_ticks := 30
## On: when a swing starts, on the server, enemies within its reach and in front of the pawn are told it's coming (their
## AIContextComponent.note_incoming_attack), so their AI can parry. One sphere query a swing.
@export var warns_targets := true

var _made_default_steps := false # true when it made its own steps from its settings


func _init() -> void:
	super()
	kind = Kind.ACTION
	trigger_action = &"primary"
	# Tags as Tags constants (tags/Tags.gd), so a misspelling is an error, not a warning while playing.
	category = Tags.COMBAT_MELEE
	locks_out = [Tags.MOVEMENT, Tags.COMBAT]
	interrupt_priority = 15
	interrupt_threshold = 15
	buffer_window = 0.15 # a press near the end of a dash waits for it
	combo_positions = [1] # an opener, unless a scene says it's a follow-up (pawn spec 8.20)


# Its steps time and run the swing, and the base handles a stepped ability's timer and rollback, so it has no duration_ticks,
# get_rollback_properties or tick of its own.


## Finds its steps, after making the default ones from its settings if it has none of its own.
func collect_steps() -> void:
	var has_own := false
	for child in get_children():
		if child is AbilityStep:
			has_own = true
			break
	if not has_own:
		_make_default_steps()
	super()
	if _made_default_steps:
		_sync_default_steps()


func start() -> void:
	# No snap to where the pawn looks (the owner's request): its TurnToFace step turns it, so a turn speed limits every attack.
	# Its made steps take its settings again, in case they were changed while playing (a test, a tuning panel).
	if _made_default_steps:
		_sync_default_steps()
	if warns_targets and pawn.is_authority() and not _is_replaying():
		_warn_targets()


# The steps of a swing, from its settings: Windup (starts TurnToFace; then Sweep), TurnToFace, Sweep (then OpenCombo and Recovery),
# OpenCombo, Recovery. Named the same everywhere, so their rolled-back state has the same paths on every machine.
func _make_default_steps() -> void:
	var windup := WindupStep.new()
	windup.name = "Windup"
	windup.starts_first = true
	windup.turn_step = NodePath("../TurnToFace")
	windup.starts_when_finished = [NodePath("../Sweep")]
	add_child(windup)
	var turn := TurnToFaceStep.new()
	turn.name = "TurnToFace"
	add_child(turn)
	var sweep := MeleeSweepStep.new()
	sweep.name = "Sweep"
	sweep.starts_when_finished = [NodePath("../OpenCombo"), NodePath("../Recovery")]
	add_child(sweep)
	var combo := OpenComboStep.new()
	combo.name = "OpenCombo"
	add_child(combo)
	var recovery := WaitStep.new()
	recovery.name = "Recovery"
	add_child(recovery)
	_made_default_steps = true


# Copies its settings onto the steps it made.
func _sync_default_steps() -> void:
	var windup := get_node(^"Windup") as WindupStep
	var turn := get_node(^"TurnToFace") as TurnToFaceStep
	var sweep := get_node(^"Sweep") as MeleeSweepStep
	var recovery := get_node(^"Recovery") as WaitStep
	windup.length_ticks = windup_ticks
	turn.degrees_per_second = windup_turn_degrees_per_second
	sweep.length_ticks = hit_ticks
	sweep.hit_radius = hit_radius
	sweep.hits_own_team = hits_own_team
	# Right to left by default: the right is a negative angle. sweep_from_left turns it round.
	var side := 1.0 if sweep_from_left else -1.0
	sweep.start_angle = side * sweep_degrees * 0.5
	sweep.end_angle = -side * sweep_degrees * 0.5
	sweep.start_height = hit_height + height_at_sweep_start
	sweep.end_height = hit_height + height_at_sweep_end
	sweep.start_reach = attack_range
	sweep.end_reach = attack_range
	recovery.length_ticks = recovery_ticks
	(get_node(^"OpenCombo") as OpenComboStep).window_ticks = combo_window_ticks


# Its first windup, or null. The visuals and the target warning read the swing's shape through its first windup and first sweep.
func _first_windup() -> WindupStep:
	for step in steps:
		if step is WindupStep:
			return step
	return null


# How fast its first TurnToFace step turns now, in degrees a second; 0 with none.
func _turn_speed() -> float:
	for step in steps:
		if step is TurnToFaceStep:
			return (step as TurnToFaceStep).current_speed()
	return 0.0


func _first_sweep() -> MeleeSweepStep:
	for step in steps:
		if step is MeleeSweepStep:
			return step
	return null


## Where the swing is, for visuals that follow its phases, such as the floating sword: "windup", "hit" or "recovery" with how far
## through it is (0 to 1, smooth between ticks), or "none" when it isn't swinging. Read from its running steps.
func swing_phase() -> Dictionary:
	for step in steps:
		if step.running and step is MeleeSweepStep:
			return {"phase": "hit", "progress": step.progress()}
	for step in steps:
		if step.running and step is WindupStep:
			return {"phase": "windup", "progress": step.progress()}
	for step in steps:
		if step.running and step is WaitStep:
			return {"phase": "recovery", "progress": step.progress()}
	return {"phase": "none", "progress": 0.0}


# Tells enemies this swing may reach that it's coming, and when its hit starts. Within attack_range plus hit_radius, and within the
# sweep's width (plus 30 degrees to spare) of where the pawn will face when the hit starts: its facing turned toward where it looks,
# as far as its TurnToFace step's speed allows over the windup.
func _warn_targets() -> void:
	var reach := attack_range + hit_radius
	var sphere := SphereShape3D.new()
	sphere.radius = reach
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, pawn.global_position + Vector3(0.0, 0.9, 0.0))
	query.collision_mask = pawn.collision_layer
	query.exclude = [pawn.get_rid()]
	var turn := deg_to_rad(_turn_speed()) * float(windup_length()) / TickDriver.get_tick_rate()
	var hit_yaw := rotate_toward(pawn.yaw, look_yaw(), turn)
	var facing := Vector3(-sin(hit_yaw), 0.0, -cos(hit_yaw))
	var widest := deg_to_rad(sweep_degrees * 0.5 + 30.0)
	var now: int = TickDriver.tick
	for found in pawn.get_world_3d().direct_space_state.intersect_shape(query, 16):
		var other := found.collider as Pawn
		if other == null or other.team == pawn.team or other.is_dead():
			continue
		var to := other.global_position - pawn.global_position
		to.y = 0.0
		if to.length_squared() > 0.0001 and facing.angle_to(to.normalized()) > widest:
			continue
		# Straight to the target's AI, on the server, while it's alive.
		if other.ai_context and other.is_authority() and not other.is_dead():
			other.ai_context.note_incoming_attack(pawn, now, now + windup_length())


func _is_replaying() -> bool:
	var driver: Node = pawn.get_node_or_null("/root/TickDriver")
	return driver != null and driver.is_resimulating()


## Where the hit sphere is straight ahead: the middle of the sweep. With a sweep, see [method hit_centre_at].
func hit_centre() -> Vector3:
	return hit_centre_at(0.5)


## Where the hit sphere is at this point of the sweep, from 0 (its start) to 1 (its end), for the pawn's facing now. Answered by its
## first sweep step.
func hit_centre_at(progress: float) -> Vector3:
	return pawn.global_position + hit_offset_at(progress, pawn.yaw)


## The same as [method hit_centre_at], from the pawn's feet, for a facing given in radians. The floating sword uses it with the facing
## it draws, which is smoothed between ticks, so it swings through exactly the spots the hit checks. From its first sweep step
## (MeleeSweepStep.offset_at); straight ahead at chest height if it has none.
func hit_offset_at(progress: float, facing: float) -> Vector3:
	var sweep := _first_sweep()
	if sweep == null:
		return Vector3(-sin(facing), 0.0, -cos(facing)) * maxf(attack_range - hit_radius, 0.0) + Vector3(0.0, hit_height, 0.0)
	return sweep.offset_at(progress, facing)


## How long a swing takes when it doesn't wait for its turn: its first windup, sweep and recovery, at this match's tick rate. 0 with
## none of them. For tests and tools; a real swing can take longer while its windup waits.
func planned_ticks() -> int:
	var total := windup_length() + hit_length()
	for step in steps:
		if step is WaitStep:
			total += step.length()
			break
	return total


## How many ticks the windup lasts, at this match's tick rate: its first windup's length. For visuals that follow the swing's phases,
## such as the floating sword. The windup can take longer while it waits for the turn ([method swing_phase] says where it really is).
func windup_length() -> int:
	var windup := _first_windup()
	return windup.length() if windup else 0


## How many ticks it can hit for, at this match's tick rate: its first sweep's length.
func hit_length() -> int:
	var sweep := _first_sweep()
	return sweep.length() if sweep else 0


# The spots the sphere passes through on this hit tick (0 for the first): its first sweep's.
# REFACTOR: only visuals/tests/visuals_selftest calls this; the test could ask the sweep step (centres_for_tick) itself. Test
# helpers stay out of production code.
func _sweep_centres(hit_tick: int) -> Array[Vector3]:
	var sweep := _first_sweep()
	return sweep.centres_for_tick(hit_tick) if sweep else [hit_centre()] as Array[Vector3]
