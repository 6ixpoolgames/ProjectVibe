# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## A melee swing: an action bound to &"primary", built from steps.
##
## A swing is a [WindupStep] with a [TurnToFaceStep] beside it, a [MeleeSweepStep] (the hit window), then an [OpenComboStep] and a
## [WaitStep] for recovery. With no [AbilityStep] children of its own it makes those from the settings below, about 0.4 s with the
## defaults; place steps of your own for another pattern (these settings then only matter for [member attack_range], the AI's reach, and
## [member warns_targets]). It locks out movement and other combat; Dash cancels it, Sprint and Jump don't. Hits happen on the server
## only, during the sweep, and a replay never hits again. What a hit does is its hit definition's effects ([member AbilityDefinition.hit]), not the swing itself.
## Design: pawn spec 8.6, 8.9, 8.20.
class_name MeleeAttackAbility
extends AbilityBase

# Its settings with their own type: the same object as settings.
var _melee: MeleeAttackDefinition = null

# Its settings, read from its definition (ability spec 3). Writing one is for a script's _init(); see AbilityBase._write_setting.

var _made_default_steps := false # true when it made its own steps from its settings


# Its steps time and run the swing and the base handles the timer and rollback, so it has no duration_ticks, get_rollback_properties
# or tick of its own.


## Its kind's defaults: a new [MeleeAttackDefinition].
func make_default_definition() -> AbilityDefinition:
	return MeleeAttackDefinition.new()


func _settings_changed() -> void:
	super()
	_melee = settings as MeleeAttackDefinition


## Its attack_range: the AI swings from within it.
func attack_reach() -> float:
	return _melee.attack_range


## Finds its steps, after making the default ones from its settings if it has none of its own.
# REFACTOR: the same pattern as the other attack's collect_steps (default steps made once, then kept in step with the settings);
# one in AbilityBase with hooks (abilities/CHANGELOG.md).
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
	# No snap to the look: its TurnToFace step turns the pawn. The made steps take the settings again, in case they changed in play.
	if _made_default_steps:
		_sync_default_steps()
	if _melee.warns_targets and pawn.is_authority() and not TickDriver.is_resimulating():
		_warn_targets()


# The default steps, run by its default timeline. Named the same everywhere, so a definition's own timeline can name them.
func _make_default_steps() -> void:
	var windup := WindupStep.new()
	windup.name = "Windup"
	add_child(windup)
	var turn := TurnToFaceStep.new()
	turn.name = "TurnToFace"
	add_child(turn)
	var sweep := MeleeSweepStep.new()
	sweep.name = "Sweep"
	add_child(sweep)
	var combo := OpenComboStep.new()
	combo.name = "OpenCombo"
	add_child(combo)
	var recovery := WaitStep.new()
	recovery.name = "Recovery"
	add_child(recovery)
	_made_default_steps = true


## The timeline for the steps it made: Windup and TurnToFace together, Sweep when the windup is done, then OpenCombo and Recovery.
## With steps of its own and no timeline in its definition, they run one after another.
func default_timeline() -> Array[TimelineEntry]:
	if not _made_default_steps:
		return []
	return [TimelineEntry.at(&"Windup"), TimelineEntry.at(&"TurnToFace"), TimelineEntry.after_end_of(&"Sweep", &"Windup"),
		TimelineEntry.after_end_of(&"OpenCombo", &"Sweep"), TimelineEntry.after_end_of(&"Recovery", &"Sweep")]


# Copies its settings onto the steps it made.
func _sync_default_steps() -> void:
	var windup := get_node(^"Windup") as WindupStep
	var turn := get_node(^"TurnToFace") as TurnToFaceStep
	var sweep := get_node(^"Sweep") as MeleeSweepStep
	var recovery := get_node(^"Recovery") as WaitStep
	windup.length_ticks = _melee.windup_ticks
	turn.degrees_per_second = _melee.windup_turn_degrees_per_second
	sweep.length_ticks = _melee.hit_ticks
	sweep.hit_radius = _melee.hit_radius
	# Right to left by default: the right is a negative angle. sweep_from_left turns it round.
	var side := 1.0 if _melee.sweep_from_left else -1.0
	sweep.start_angle = side * _melee.sweep_degrees * 0.5
	sweep.end_angle = -side * _melee.sweep_degrees * 0.5
	sweep.start_height = _melee.hit_height + _melee.height_at_sweep_start
	sweep.end_height = _melee.hit_height + _melee.height_at_sweep_end
	sweep.start_reach = _melee.attack_range
	sweep.end_reach = _melee.attack_range
	sweep.keys = _melee.sweep_keys # a path of its own, when it has one
	recovery.length_ticks = _melee.recovery_ticks
	(get_node(^"OpenCombo") as OpenComboStep).window_ticks = _melee.combo_window_ticks


# Its first windup, or null. Visuals and the target warning read the swing's shape through its first windup and sweep.
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


## Where the swing is, for visuals: "windup", "hit" or "recovery" with progress 0 to 1 (smooth between ticks), or "none".
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


# Tells enemies the swing may reach that it's coming, and when its hit starts: within attack_range plus hit_radius, and within the
# sweep's width (plus 30 degrees) of where the pawn will face when the hit starts, turned as far as its TurnToFace speed allows.
func _warn_targets() -> void:
	var reach := _melee.attack_range + _melee.hit_radius
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
	var widest := deg_to_rad(_melee.sweep_degrees * 0.5 + 30.0)
	var now: int = TickDriver.tick
	for found in pawn.get_world_3d().direct_space_state.intersect_shape(query, 16):
		var other := found.collider as Pawn
		if other == null or other.team == pawn.team or other.is_dead():
			continue
		var to := other.global_position - pawn.global_position
		to.y = 0.0
		if to.length_squared() > 0.0001 and facing.angle_to(to.normalized()) > widest:
			continue
		# Straight to the target's AI, on the server.
		if other.ai_context and other.is_authority():
			other.ai_context.note_incoming_attack(pawn, now, now + windup_length())



## Where the hit sphere is straight ahead: the middle of the sweep. With a sweep, see [method hit_centre_at].
func hit_centre() -> Vector3:
	return hit_centre_at(0.5)


## Where the hit sphere is at this point of the sweep, 0 (start) to 1 (end), for the pawn's facing now. Answered by its first sweep step.
func hit_centre_at(progress: float) -> Vector3:
	return pawn.global_position + hit_offset_at(progress, pawn.yaw)


## Like [method hit_centre_at], as an offset from the pawn's feet for a facing in radians, so visuals draw the spots the hit checks.
## From [method MeleeSweepStep.offset_at]; straight ahead at chest height with no sweep.
func hit_offset_at(progress: float, facing: float) -> Vector3:
	var sweep := _first_sweep()
	if sweep == null:
		return Vector3(-sin(facing), 0.0, -cos(facing)) * maxf(_melee.attack_range - _melee.hit_radius, 0.0) + Vector3(0.0, _melee.hit_height, 0.0)
	return sweep.offset_at(progress, facing)


## Ticks a swing takes if its windup doesn't wait for the turn: first windup, sweep and recovery. 0 with none. For tests and tools.
# REFACTOR: only tests call it (with hit_centre_at, and hit_centre through _sweep_centres): the test-only helper row in CHANGELOG.md.
func planned_ticks() -> int:
	var total := windup_length() + hit_length()
	for step in steps:
		if step is WaitStep:
			total += step.length()
			break
	return total


## Ticks the first windup lasts. It can take longer while it waits for the turn; [method swing_phase] says where it really is.
func windup_length() -> int:
	var windup := _first_windup()
	return windup.length() if windup else 0


## Ticks the first sweep can hit for.
func hit_length() -> int:
	var sweep := _first_sweep()
	return sweep.length() if sweep else 0


# The spots the sphere passes through on this hit tick (0 for the first): its first sweep's.
# REFACTOR: only visuals/tests/visuals_selftest calls this; the test could ask the sweep step (centres_for_tick) itself. Test
# helpers stay out of production code.
func _sweep_centres(hit_tick: int) -> Array[Vector3]:
	var sweep := _first_sweep()
	return sweep.centres_for_tick(hit_tick) if sweep else [hit_centre()] as Array[Vector3]
