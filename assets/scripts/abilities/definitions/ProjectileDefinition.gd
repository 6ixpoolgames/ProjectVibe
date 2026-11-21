# Written by Claude (claude-opus-5-5), 2026-11-22. History: abilities/CHANGELOG.md.
@tool
## A projectile's flight and hits, shared by every shot that uses it (ability spec 9): its speed and how it changes, how much it drops,
## its size, how far and long it flies, what stops it, how many pawns it passes through, and what's shown where it ends.
##
## The one thing a designer makes for a new projectile: a ranged attack's definition names it
## ([member RangedAttackDefinition.projectile_definition]), and the built-in projectile carries the networking. Variants come from
## [Definition]. Save it as a file in a registry folder, so clients find it by its index.
class_name ProjectileDefinition
extends Definition

## Metres a second at launch (times the speed curve's first value).
@export_range(0.5, 500.0, 0.5, "or_greater") var speed: float = 30.0:
	set(value):
		speed = value
		_changed(&"speed", value)
## How its speed changes over its flight: across, 0 to 1 through its lifetime; up, a multiplier on [member speed]. Empty: steady. A
## rocket rises, an arrow falls away. Gravity's drop comes on top.
@export var speed_curve: Curve:
	set(value):
		speed_curve = value
		_changed(&"speed_curve", value)
## How much it drops, as a share of the world's gravity (physics/3d/default_gravity): 0 flies straight, 1 falls like a stone, 2 feels
## heavy. Tuning for how weighty it reads, not physics.
@export_range(0.0, 10.0, 0.05, "or_greater") var gravity_scale: float = 0.0:
	set(value):
		gravity_scale = value
		_changed(&"gravity_scale", value)
## Radius of the hit sphere swept along its path, in metres.
@export_range(0.01, 5.0, 0.01, "or_greater") var radius: float = 0.15:
	set(value):
		radius = value
		_changed(&"radius", value)
## Metres it can fly before it's gone.
@export_range(0.5, 1000.0, 0.5, "or_greater") var max_range: float = 40.0:
	set(value):
		max_range = value
		_changed(&"max_range", value)
## Seconds it can fly before it's gone.
@export_range(0.1, 60.0, 0.1, "or_greater") var max_lifetime: float = 3.0:
	set(value):
		max_lifetime = value
		_changed(&"max_lifetime", value)
## How many pawns it hits before it stops: 1 stops at the first, 0 passes through every pawn. Each pawn is hit once.
@export_range(0, 100, 1, "or_greater") var max_hits: int = 1:
	set(value):
		max_hits = value
		_changed(&"max_hits", value)
## Ends it after this many intersects of any kind (pawns it may or may not hit, the world). 0: no limit.
@export_range(0, 100, 1, "or_greater") var max_intersects: int = 0:
	set(value):
		max_intersects = value
		_changed(&"max_intersects", value)

@export_group("Whitelist")
## On: it can hit the pawn that fired it, once it has left its body.
@export var hits_shooter: bool = false:
	set(value):
		hits_shooter = value
		_changed(&"hits_shooter", value)
## On: it can hit pawns on the shooter's team.
@export var hits_allies: bool = false:
	set(value):
		hits_allies = value
		_changed(&"hits_allies", value)
## On: it can hit pawns on other teams.
@export var hits_enemies: bool = true:
	set(value):
		hits_enemies = value
		_changed(&"hits_enemies", value)
## Effects on a pawn it hits, as well as the firing ability's on-hit effects: a fire arrow burns whichever bow fires it.
@export var on_hit_effects: Array[Effect] = []:
	set(value):
		on_hit_effects = value
		_changed(&"on_hit_effects", value)
@export_group("")

## On: the level's solid geometry (world_mask) stops it.
@export var hits_world: bool = true:
	set(value):
		hits_world = value
		_changed(&"hits_world", value)
## The physics layers that stop it (the ground and walls).
@export_flags_3d_physics var world_mask: int = 1:
	set(value):
		world_mask = value
		_changed(&"world_mask", value)
## How it looks in flight: any scene (a mesh, particles, a trail), turned to face along its flight (-Z forward). Empty: nothing is drawn,
## but it still flies and hits.
@export var visual_scene: PackedScene:
	set(value):
		visual_scene = value
		_changed(&"visual_scene", value)
## Spawned where it ends, on a pawn or the world, on every machine that draws it: a spark, a puff of dust. Its own node in the world,
## not part of the projectile, and a visual: it isn't sent, so a gameplay effect (an explosion that hurts) belongs in a hit's effects.
@export var impact_scene: PackedScene:
	set(value):
		impact_scene = value
		_changed(&"impact_scene", value)
## Seconds an impact stays before it's freed (0: it frees itself).
@export_range(0.0, 30.0, 0.1, "or_greater") var impact_seconds: float = 2.0:
	set(value):
		impact_seconds = value
		_changed(&"impact_seconds", value)

# Distance flown along its direction by each whole tick, at the rate it was worked out for: the speed curve, summed once.
var _distances := PackedFloat32Array()
var _distances_rate := -1


## Its drop in metres a second squared: the world's gravity times [member gravity_scale].
func drop_per_second_squared() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * gravity_scale


## How many ticks it flies before its lifetime is up, at the match's rate.
func lifetime_ticks() -> int:
	return maxi(1, roundi(max_lifetime * TickDriver.get_tick_rate()))


## Where it is this many ticks after launch (a fraction is between ticks), from its launch point, fired along direction (length 1).
## Worked out, not stepped, so every machine gets the same point for the same tick.
func offset_at(direction: Vector3, age: float) -> Vector3:
	var seconds := age / float(TickDriver.get_tick_rate())
	return direction * distance_at(age) + Vector3(0.0, -0.5 * drop_per_second_squared() * seconds * seconds, 0.0)


## Its velocity this many ticks after launch, fired along direction (length 1).
func velocity_at(direction: Vector3, age: float) -> Vector3:
	var seconds := age / float(TickDriver.get_tick_rate())
	return direction * speed_at(age) + Vector3(0.0, -drop_per_second_squared() * seconds, 0.0)


## Its speed along its direction this many ticks after launch: [member speed] times the curve.
func speed_at(age: float) -> float:
	if speed_curve == null:
		return speed
	return speed * speed_curve.sample(clampf(age / float(lifetime_ticks()), 0.0, 1.0))


## Metres flown along its direction this many ticks after launch.
func distance_at(age: float) -> float:
	if speed_curve == null:
		return speed * age / float(TickDriver.get_tick_rate())
	var rate: int = TickDriver.get_tick_rate()
	if _distances_rate != rate:
		_build_distances(rate)
	var whole := clampi(floori(age), 0, _distances.size() - 1)
	var past := age - whole # past the table (or between two ticks): on at the speed there
	return _distances[whole] + speed_at(whole + past * 0.5) * past / float(rate)


## Spawns its impact scene at this point, under parent: a node of its own in the world, not a child of the projectile, which lives on
## after the projectile is gone and frees itself after [member impact_seconds].
func spawn_impact(parent: Node, at: Vector3) -> void:
	if impact_scene == null or parent == null:
		return
	var impact := impact_scene.instantiate() as Node3D
	if impact == null:
		return
	# Placed before it's added, and added once the frame's work is done: an impact can come while the parent is still adding children.
	var parent_3d := parent as Node3D
	impact.transform = Transform3D(Basis.IDENTITY, parent_3d.global_transform.affine_inverse() * at if parent_3d and parent_3d.is_inside_tree() else at)
	if impact_seconds > 0.0:
		var timer := Timer.new()
		timer.one_shot = true
		timer.autostart = true
		timer.wait_time = impact_seconds
		timer.timeout.connect(impact.queue_free)
		impact.add_child(timer)
	parent.add_child.call_deferred(impact)


# Each tick's distance is its speed at the middle of the tick: the same sum on every machine.
func _build_distances(rate: int) -> void:
	_distances_rate = rate
	var ticks := lifetime_ticks()
	_distances.resize(ticks + 1)
	_distances[0] = 0.0
	for k in ticks:
		_distances[k + 1] = _distances[k] + speed_at(k + 0.5) / float(rate)
