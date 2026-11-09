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
class_name MeleeAttackAbility
extends AbilityBase

## Sent on the server for each pawn this swing hits, when the swing finds it. For effects, sounds and UI. Claude 2026-11-09: the
## target takes the hit (its damage, knockback and hit_received) later in the same tick, after every pawn has simulated.
signal hit_landed(hit: HitInfo)
## Claude 2026-11-09: sent once per swing, on its first hit tick, with where the hit sphere is and its radius. Sent on every machine
## that runs the swing (the server, offline, and a client predicting its own pawn), never during a rollback replay. For effects,
## sounds and debug drawing (AbilityDebugDraw). It says where the swing can hit, not whether it hit anything: see hit_landed.
signal hit_window_started(centre: Vector3, radius: float)

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


func duration_ticks() -> int:
	return windup_ticks + hit_ticks + recovery_ticks


func get_rollback_properties() -> Array[String]:
	var out := super()
	if not out.has("ticks_left"):
		out.append("ticks_left") # its length comes from its phases, not duration, so the base doesn't know it's timed
	return out


func start() -> void:
	pawn.yaw = pawn.look_yaw # faces where it's looking, then holds still
	_hit_this_swing.clear()


func tick(_dt: float) -> void:
	# GDScript note: the manager counts ticks_left down after each tick, so on the first tick after starting, elapsed is 0.
	var elapsed := duration_ticks() - ticks_left
	if elapsed < windup_ticks or elapsed >= windup_ticks + hit_ticks:
		return
	# Claude 2026-11-09: the replay check moved up, so hit_window_started can use it on every machine. The hit rules are unchanged.
	var driver: Node = pawn.get_node_or_null("/root/TickDriver")
	var replaying: bool = driver != null and driver.is_resimulating()
	if elapsed == windup_ticks and not replaying:
		hit_window_started.emit(hit_centre(), hit_radius)
	if not pawn.is_authority():
		return # hits are decided on the server
	if replaying:
		return # a replay never hits again
	_check_hits(driver.tick if driver else 0)


## Where the hit sphere is now.
func hit_centre() -> Vector3:
	var forward := Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw)) # Godot's forward is -Z
	return pawn.global_position + forward * maxf(attack_range - hit_radius, 0.0) + Vector3(0.0, hit_height, 0.0)


func _check_hits(tick: int) -> void:
	var centre := hit_centre()
	var targets: Array[Pawn] = []
	var entity := pawn.get_network_entity()
	# Through lag compensation in a network session; offline there's nobody to rewind, and pawns aren't tagged for it.
	if entity and entity.session:
		for found in LagCompensation.melee(entity, centre, hit_radius, pawn.view_ticks_behind):
			var other := found.get_parent() as Pawn
			if other:
				targets.append(other)
	else:
		targets = _plain_sphere(centre)
	for target in targets:
		if target == pawn or target.is_dead() or _hit_this_swing.has(target.get_instance_id()):
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
		hit.knockback_ticks = knockback_ticks
		target.receive_hit(hit)
		hit_landed.emit(hit)


# Offline, or for a pawn without a NetworkEntity: the same sphere, with no rewinding.
func _plain_sphere(centre: Vector3) -> Array[Pawn]:
	var found: Array[Pawn] = []
	var sphere := SphereShape3D.new()
	sphere.radius = hit_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, centre)
	query.exclude = [pawn.get_rid()]
	for hit in pawn.get_world_3d().direct_space_state.intersect_shape(query):
		var other := hit.collider as Pawn
		if other and not found.has(other):
			found.append(other)
	return found
