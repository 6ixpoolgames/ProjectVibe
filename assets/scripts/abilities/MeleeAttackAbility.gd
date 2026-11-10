## Written by Claude (claude-opus-5-5), 2026-11-09: a melee swing. An action bound to &"primary". Pawn spec section 8.6, step 9.
##
## Three phases, in ticks: windup_ticks (8), then hit_ticks (4) when it can hit, then recovery_ticks (12): about 0.4 s in all. It
## turns to face the pawn's look direction when it starts, then holds still: while it runs, all movement and other combat abilities
## are locked out. Dash (priority 20) cancels it, which is the player's animation cancel; Sprint (10) and Jump (5) don't, because its
## interrupt_threshold is 15. Knockback (30) staggers it.
##
## Hits, on the server only (or offline), during the hit ticks:
##   - A sphere of hit_radius, at hit_height, placed in front so its far edge is attack_range from the pawn. attack_range is the
##     attack's real reach; the AI's Attack behaviour steps in to attack_range minus its approach_margin before swinging.
##   - Checked through LagCompensation.melee, so a player's swing is judged against where they saw other pawns: the pawn's input
##     carries view_ticks_behind, and the server limits it to what's believable. The AI's swings use 0.
##   - Each pawn is hit at most once per swing. Its own team is skipped unless hits_own_team is on.
##   - Each hit calls the target's Pawn.receive_hit() with a HitInfo, which starts the target's own knockback, and sends hit_landed
##     here, for local effects such as sounds. Claude 2026-11-09: the target takes the hit after every pawn has simulated this tick
##     (pawn spec 15.4), so hit_landed goes out first. Claude 2026-11-09: each hit also takes damage health points (step 10); dead pawns
##     aren't hit.
## A rollback replay never hits again: hits are decided once, on the authority, outside replays.
##
## Claude 2026-11-10, a game feel pass (the owner's request):
##   - The hit area moves: during the hit ticks the sphere sweeps across sweep_degrees (100) in front of the pawn, from its right to
##     its left (sweep_from_left turns it round), at the same reach. Each tick checks every spot the sphere passes through in that
##     tick, no more than half its radius apart, so a fast sweep or a 30 Hz match leaves no gaps; they're checked in one lag
##     compensation rewind (LagCompensation.melee_spheres). sweep_degrees 0 is the old sphere that holds still, straight ahead.
##   - It turns during the windup: toward where the pawn looks, at up to windup_turn_degrees_per_second (720), so a swing started a
##     little off still lands where the player (or the AI) is looking. From the first hit tick it holds still, as before. 0: it holds
##     still from the start, as before.
##   - A hit can lift the target in a small hop: knockback_hop_speed, in metres per second upward (KnockbackAbility).
##   - hit_area_moved goes out on every hit tick, for debug drawing the sweep.
class_name MeleeAttackAbility
extends AbilityBase

## Sent on the server for each pawn this swing hits, when the swing finds it. For effects, sounds and UI. Claude 2026-11-09: the
## target takes the hit (its damage, knockback and hit_received) later in the same tick, after every pawn has simulated.
signal hit_landed(hit: HitInfo)
## Claude 2026-11-09: sent once per swing, on its first hit tick, with where the hit sphere is and its radius. Sent on every machine
## that runs the swing (the server, offline, and a client predicting its own pawn), never during a rollback replay. For effects,
## sounds and debug drawing (AbilityDebugDraw). It says where the swing can hit, not whether it hit anything: see hit_landed.
signal hit_window_started(centre: Vector3, radius: float)
## Claude 2026-11-10: sent on every hit tick, on the same machines as hit_window_started, with where the hit sphere was at the start and
## the end of this tick's part of the sweep. For effects and debug drawing (AbilityDebugDraw draws the sweep with it).
signal hit_area_moved(from: Vector3, to: Vector3, radius: float)

## Ticks from the start of the swing to when it can hit.
@export_range(0, 120, 1, "or_greater") var windup_ticks := 8
## Ticks it can hit for.
@export_range(1, 120, 1, "or_greater") var hit_ticks := 4
## Ticks after hitting before it's over.
@export_range(0, 120, 1, "or_greater") var recovery_ticks := 12
## How far it reaches, in metres from the pawn: the far edge of the hit sphere.
@export_range(0.1, 20.0, 0.05, "or_greater") var attack_range := 1.8
## The hit sphere's radius, in metres.
@export_range(0.05, 10.0, 0.05, "or_greater") var hit_radius := 0.8
## The hit sphere's height above the pawn's feet, in metres: about the chest.
@export var hit_height := 1.0
## Claude 2026-11-09, step 10: health points each hit takes.
@export_range(0, 10000, 1, "or_greater") var damage := 20
## How fast a hit pushes the target, in metres per second at the start.
@export var knockback_speed := 6.0
## How many ticks a hit's push lasts.
@export_range(0, 120, 1, "or_greater") var knockback_ticks := 10
## On: it can hit pawns on its own team.
@export var hits_own_team := false
## Claude 2026-11-10: how far round the hit sphere sweeps during the hit ticks, in degrees, centred straight ahead. 0: it holds still.
@export_range(0.0, 360.0, 1.0) var sweep_degrees := 100.0
## Claude 2026-11-10: on: the sweep goes from the pawn's left to its right. Off (the default): right to left.
@export var sweep_from_left := false
## Claude 2026-11-10: how fast it turns toward where the pawn looks during the windup, in degrees per second. 0: no turning.
@export_range(0.0, 3600.0, 10.0, "or_greater") var windup_turn_degrees_per_second := 720.0
## Claude 2026-11-10: how fast a hit lifts the target, in metres per second upward, for a small hop back. 0: no hop.
@export_range(0.0, 20.0, 0.1, "or_greater") var knockback_hop_speed := 2.0

var _hit_this_swing: Array[int] = [] # instance ids, on the server only


func _init() -> void:
	super()
	kind = Kind.ACTION
	trigger_action = &"primary"
	category = &"combat.melee"
	locks_out = [&"movement", &"combat"]
	interrupt_priority = 15
	interrupt_threshold = 15
	buffer_window = 0.15 # a press near the end of a dash waits for it


# Claude 2026-11-09 (scaling spec step 6): the phases are written for 60 ticks a second, and converted to this match's rate.
func duration_ticks() -> int:
	return _windup() + _hit() + TickDriver.ticks_at_rate(recovery_ticks)


func _windup() -> int:
	return TickDriver.ticks_at_rate(windup_ticks)


func _hit() -> int:
	return TickDriver.ticks_at_rate(hit_ticks)


func get_rollback_properties() -> Array[String]:
	var out := super()
	if not out.has("ticks_left"):
		out.append("ticks_left") # its length comes from its phases, not duration, so the base doesn't know it's timed
	return out


func start() -> void:
	pawn.yaw = pawn.look_yaw # faces where it's looking, then holds still
	_hit_this_swing.clear()


func tick(dt: float) -> void:
	# GDScript note: the manager counts ticks_left down after each tick, so on the first tick after starting, elapsed is 0.
	var elapsed := duration_ticks() - ticks_left
	# Claude 2026-11-10: the windup turns toward where the pawn looks. yaw rolls back, and look_yaw is input, so a replay turns the
	# same way. GDScript note: rotate_toward() turns an angle toward another by at most the step, the short way round.
	if elapsed < _windup():
		if windup_turn_degrees_per_second > 0.0:
			pawn.yaw = rotate_toward(pawn.yaw, pawn.look_yaw, deg_to_rad(windup_turn_degrees_per_second) * dt)
		return
	if elapsed >= _windup() + _hit():
		return
	# Claude 2026-11-09: the replay check moved up, so hit_window_started can use it on every machine. The hit rules are unchanged.
	var driver: Node = pawn.get_node_or_null("/root/TickDriver")
	var replaying: bool = driver != null and driver.is_resimulating()
	# Claude 2026-11-10: this tick's part of the sweep, as spots along it.
	var centres := _sweep_centres(elapsed - _windup())
	if not replaying:
		if elapsed == _windup():
			hit_window_started.emit(centres[0], hit_radius)
		hit_area_moved.emit(centres[0], centres[centres.size() - 1], hit_radius)
	if not pawn.is_authority():
		return # hits are decided on the server
	if replaying:
		return # a replay never hits again
	_check_hits(driver.tick if driver else 0, centres)


## Where the hit sphere is straight ahead: the middle of the sweep. Claude 2026-11-10: with a sweep, see hit_centre_at.
func hit_centre() -> Vector3:
	return hit_centre_at(0.5)


## Claude 2026-11-10: where the hit sphere is at this point of the sweep, from 0 (its start) to 1 (its end), for the pawn's facing now.
## The sphere stays at the same reach, so its far edge is always attack_range from the pawn.
func hit_centre_at(progress: float) -> Vector3:
	# Godot's forward is -Z, and a pawn's right is a smaller yaw: forward at yaw - 90 degrees is +X.
	var side := 1.0 if sweep_from_left else -1.0
	var angle := pawn.yaw + side * deg_to_rad(sweep_degrees) * (0.5 - progress)
	var forward := Vector3(-sin(angle), 0.0, -cos(angle))
	return pawn.global_position + forward * maxf(attack_range - hit_radius, 0.0) + Vector3(0.0, hit_height, 0.0)


## Claude 2026-11-10: the spots the sphere passes through on this hit tick (0 for the first): from where it was at the start of the tick
## to where it is at the end, no more than half its radius apart, so the checks overlap with no gaps. One spot with no sweep.
func _sweep_centres(hit_tick: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if sweep_degrees <= 0.0:
		out.append(hit_centre_at(0.5))
		return out
	var ticks := float(_hit())
	var start := hit_tick / ticks
	var end := (hit_tick + 1) / ticks
	var arc_length := maxf(attack_range - hit_radius, 0.0) * deg_to_rad(sweep_degrees) / ticks # metres this tick sweeps
	var steps := maxi(1, ceili(arc_length / maxf(hit_radius * 0.5, 0.01)))
	for i in steps + 1:
		out.append(hit_centre_at(lerpf(start, end, float(i) / steps)))
	return out


func _check_hits(tick: int, centres: Array[Vector3]) -> void:
	var targets: Array[Pawn] = []
	var entity := pawn.get_network_entity()
	# Through lag compensation in a network session; offline there's nobody to rewind, and pawns aren't tagged for it.
	if entity and entity.session:
		for found in LagCompensation.melee_spheres(entity, centres, hit_radius, pawn.view_ticks_behind): # Claude 2026-11-10: was melee
			var other := found.get_parent() as Pawn
			if other:
				targets.append(other)
	else:
		targets = _plain_spheres(centres) # Claude 2026-11-10: was one sphere
	for target in targets:
		if target == pawn or target.is_dead() or _hit_this_swing.has(target.get_instance_id()):
			continue
		# Claude 2026-11-10: a dashing pawn isn't hit, and isn't marked as hit either, so the rest of the sweep can catch it once its
		# dash ends.
		if target.is_invulnerable():
			continue
		if target.team == pawn.team and not hits_own_team:
			continue
		_hit_this_swing.append(target.get_instance_id())
		var hit := HitInfo.new()
		hit.attacker = pawn
		hit.target = target
		hit.ability = self
		hit.tick = tick
		var away := target.global_position - pawn.global_position
		away.y = 0.0
		hit.direction = away.normalized() if away.length_squared() > 0.0001 else Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw))
		hit.damage = damage
		hit.knockback_speed = knockback_speed
		hit.knockback_ticks = TickDriver.ticks_at_rate(knockback_ticks) # Claude 2026-11-09 (step 6)
		hit.knockback_hop = knockback_hop_speed # Claude 2026-11-10
		target.receive_hit(hit)
		hit_landed.emit(hit)


# Offline, or for a pawn without a NetworkEntity: the same spheres, with no rewinding. Claude 2026-11-10: several, for the sweep.
func _plain_spheres(centres: Array[Vector3]) -> Array[Pawn]:
	var found: Array[Pawn] = []
	var sphere := SphereShape3D.new()
	sphere.radius = hit_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.exclude = [pawn.get_rid()]
	var space := pawn.get_world_3d().direct_space_state
	for centre in centres:
		query.transform = Transform3D(Basis.IDENTITY, centre)
		for hit in space.intersect_shape(query):
			var other := hit.collider as Pawn
			if other and not found.has(other):
				found.append(other)
	return found
