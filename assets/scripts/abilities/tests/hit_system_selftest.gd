## Written by Claude (claude-opus-5-5), 2026-11-22: headless self-test for the shared hit system (ability spec 13): a swing's whitelist
## and its log, swapping hit definitions while playing, a cap on hits, a sweep step's own hit definition, swing keys, a sweep left in
## the world, a projectile's end worked out at launch (a wall, the floor under an arc), hitscan, a hit landing without its source, and a
## removed shooter lingering until its bolt ends, the world blocking a swing along the weapon's reach, and walls a bolt goes through by
## their physics layer.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/abilities/tests/hit_system_selftest.tscn"
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]
const BOLT := preload("res://assets/scripts/resources/abilities/bolt.tres")


func _ready() -> void:
	print("--- Hit system self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	Projectile.register()
	_floor()
	_test_keys()
	await _test_whitelist_and_swap()
	await _test_cleave_cap()
	await _test_step_hit()
	await _test_world_anchor()
	await _test_planned_end()
	await _test_hitscan()
	await _test_lands_without_source()
	await _test_linger()
	await _test_melee_walls()
	await _test_wall_layers()
	_finish()


# Three keys: the path goes through the middle one, and in between, straight from key to key.
func _test_keys() -> void:
	var sweep := MeleeSweepStep.new()
	sweep.keys = [SweepKey.make(1.0, 50.0, 1.0, 1.8), SweepKey.make(0.0, -50.0, 1.0, 1.8), SweepKey.make(0.5, 0.0, 2.0, 2.4)]
	_check(sweep.path_point(0.5).is_equal_approx(Vector3(0.0, 2.0, 2.4)), "a swing's path goes through its keys, in order of their time (%s)" % sweep.path_point(0.5))
	_check(sweep.path_point(0.25).is_equal_approx(Vector3(-25.0, 1.5, 2.1)), "and straight from key to key between them (%s)" % sweep.path_point(0.25))
	sweep.keys = []
	_check(sweep.path_point(0.5).is_equal_approx(Vector3(0.0, 1.0, 1.8)), "with no keys, from its start to its end")
	sweep.free()


# An ally straight ahead: by default the swing meets it but doesn't hit it, and says so; with a hit definition that hits allies swapped
# in while playing, it does.
func _test_whitelist_and_swap() -> void:
	var attacker := _pawn(Vector3(0, 0.1, 0), 0)
	var ally := _pawn(Vector3(0, 0.1, -1.3), 0)
	var ally_hits := _hits_on(ally)
	await _ticks(10)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var met: Array = []
	melee.intersected.connect(func(entry: Dictionary) -> void: met.append([entry.target, entry.hit]))
	await _swing(attacker, melee)
	_check(met == [[ally, false]] and ally_hits.is_empty(), "a swing meets an ally without hitting it, and its log says so (%s)" % str(met))
	var friendly := HitDefinition.new()
	friendly.hits_allies = true
	melee.use_hit_definition(friendly)
	await _swing(attacker, melee)
	_check(ally_hits.size() == 1, "with a hit definition that hits allies swapped in while playing, it hits the ally")
	melee.use_hit_definition(null)
	await _free(attacker, ally)


# Three enemies in the arc and a hit definition with max_hits 2: the swing hits two and no more (a cleave cap).
func _test_cleave_cap() -> void:
	var attacker := _pawn(Vector3(20, 0.1, 0), 0)
	var enemies: Array[Pawn] = []
	var counts: Array = []
	for degrees: float in [-40.0, 0.0, 40.0]:
		var enemy := _pawn(Vector3(20, 0.1, 0) + _flat_at(degrees, 1.4), 1)
		enemies.append(enemy)
		counts.append(_hits_on(enemy))
	await _ticks(10)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var capped := HitDefinition.new()
	capped.max_hits = 2
	melee.use_hit_definition(capped)
	await _swing(attacker, melee)
	var total := 0
	for list: Array in counts:
		total += list.size()
	_check(total == 2, "a hit definition with max_hits 2 caps a swing at two pawns (%d)" % total)
	await _free(attacker, enemies[0], enemies[1], enemies[2])


# A sweep step's own hit definition, in place of its ability's: one that hits no enemies spares the target.
func _test_step_hit() -> void:
	var attacker := _pawn(Vector3(40, 0.1, 0), 0)
	var enemy := _pawn(Vector3(40, 0.1, -1.3), 1)
	var enemy_hits := _hits_on(enemy)
	await _ticks(10)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var sweep: MeleeSweepStep = melee.get_node("Sweep")
	var spare := HitDefinition.new()
	spare.hits_enemies = false
	sweep.hit = spare
	await _swing(attacker, melee)
	_check(enemy_hits.is_empty(), "a sweep step's own hit definition is used in place of its ability's")
	sweep.hit = null
	await _swing(attacker, melee)
	_check(enemy_hits.size() == 1, "and without it, the ability's")
	await _free(attacker, enemy)


# A sweep anchored in the world stays where the pawn was when it began: the pawn jumps back 6 m as it starts, and the enemy that was in
# front is still hit. Anchored to the pawn, it would miss.
func _test_world_anchor() -> void:
	for anchor: int in [MeleeSweepStep.Anchor.WORLD, MeleeSweepStep.Anchor.PAWN]:
		var x := 60.0 + anchor * 20.0
		var attacker := _pawn(Vector3(x, 0.1, 0), 0)
		var enemy := _pawn(Vector3(x, 0.1, -1.3), 1)
		var enemy_hits := _hits_on(enemy)
		await _ticks(10)
		var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
		var sweep: MeleeSweepStep = melee.get_node("Sweep")
		sweep.anchor = anchor
		attacker.ability_manager.step_started.connect(func(_ability: AbilityBase, step: AbilityStep) -> void:
			if step == sweep:
				attacker.teleport(attacker.global_position + Vector3(0, 0, 6)))
		await _swing(attacker, melee)
		if anchor == MeleeSweepStep.Anchor.WORLD:
			_check(enemy_hits.size() == 1, "a sweep anchored in the world stays where it began: the pawn moved away, the enemy is still hit")
		else:
			_check(enemy_hits.is_empty(), "anchored to the pawn, it moves with it, and misses")
		await _free(attacker, enemy)


# A straight bolt at a wall 10 m ahead, and an arc down onto the floor: each one's end is worked out at launch, matching a tick-by-tick
# trace, and it ends there.
func _test_planned_end() -> void:
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 0.5)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(100, 1.5, -10.25)
	add_child(wall)
	var shooter := _pawn(Vector3(100, 0.1, 0), 0)
	await _ticks(10)
	var melee: AbilityBase = shooter.ability_manager.get_node("MeleeAttack")
	var bolt := Projectile.fire(melee, Vector3(100, 1.3, -0.5), Vector3.FORWARD, BOLT)
	_check(absf(bolt.end_point.z - (-10.0)) < 0.01 and bolt.end_tick == 19, "a straight bolt's end is worked out at launch: the wall face, 9.5 m away, tick 19 (z %.2f, tick %d)" % [bolt.end_point.z, bolt.end_tick])
	var ended := {"at": null}
	bolt.ended.connect(func(_p: Projectile, at: Vector3) -> void: ended.at = at)
	await _ticks(25)
	_check(ended.at != null and (ended.at as Vector3).distance_to(Vector3(100, 1.3, -10.0)) < 0.01, "and it ends there")
	var lobbed: ProjectileDefinition = BOLT.duplicate()
	lobbed.gravity_scale = 1.0
	lobbed.speed = 12.0
	var arc := Projectile.fire(melee, Vector3(100, 2.0, -0.5), Vector3(1, 0.3, 0).normalized(), lobbed)
	var traced := _trace_end(arc)
	_check(arc.end_tick == traced[0] and arc.end_point.distance_to(traced[1]) < 0.01 and absf(arc.end_point.y) < 0.05,
			"an arc's end, found in coarse steps then tick by tick, is the one a tick-by-tick trace finds: the floor (tick %d, %s)" % [arc.end_tick, arc.end_point])
	await _ticks(90)
	wall.free()
	await _free(shooter)


# Hitscan: two enemies on a line, hit on the tick it's fired (with max_hits 0, both); a wall stops the line; the tracer then goes.
func _test_hitscan() -> void:
	var shooter := _pawn(Vector3(140, 0.1, 0), 0)
	var near := _pawn(Vector3(140, 0.1, -6), 1)
	var far := _pawn(Vector3(140, 0.1, -9), 1)
	var near_hits := _hits_on(near)
	var far_hits := _hits_on(far)
	await _ticks(10)
	var scan: ProjectileDefinition = BOLT.duplicate()
	scan.hitscan = true
	var through := HitDefinition.new()
	through.max_hits = 0
	var melee: AbilityBase = shooter.ability_manager.get_node("MeleeAttack")
	var shot := Projectile.fire(melee, Vector3(140, 1.3, -0.5), Vector3.FORWARD, scan, null, through)
	await _ticks(1)
	_check(near_hits.size() == 1 and far_hits.size() == 1, "hitscan hits along its whole line on the tick it's fired (max_hits 0: both)")
	_check(shot.end_tick == scan.tracer_ticks() and absf(shot.end_point.z - (-0.5 - scan.max_range)) < 0.01, "its tracer runs to its range, for tracer_seconds")
	await _ticks(scan.tracer_ticks() + 2)
	_check(not is_instance_valid(shot), "and goes once the tracer has shown")
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 0.5)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(140, 1.5, -4.25)
	add_child(wall)
	await _ticks(2)
	var blocked := Projectile.fire(melee, Vector3(140, 1.3, -0.5), Vector3.FORWARD, scan, null, through)
	await _ticks(1)
	_check(absf(blocked.end_point.z - (-4.0)) < 0.01 and near_hits.size() == 1, "a wall stops the line short of the pawns behind it")
	await _ticks(scan.tracer_ticks() + 2)
	wall.free()
	await _free(shooter, near, far)


# A bolt whose shooter is removed outright (no session to keep it): with lands_without_source it still hits, with the effects it set
# off with; without, it doesn't.
func _test_lands_without_source() -> void:
	for keeps: bool in [true, false]:
		var x := 180.0 + (0.0 if keeps else 20.0)
		var shooter := _pawn(Vector3(x, 0.1, 0), 0)
		var target := _pawn(Vector3(x, 0.1, -12), 1)
		var target_hits := _hits_on(target)
		await _ticks(10)
		var rules := HitDefinition.new()
		rules.max_hits = 1
		rules.lands_without_source = keeps
		var ranged: AbilityBase = shooter.ability_manager.get_node("MeleeAttack")
		rules.target_effects = ranged.hit_definition().target_effects # Claude 2026-11-24: a hit named on its own carries its own effects
		Projectile.fire(ranged, Vector3(x, 1.3, -0.5), Vector3.FORWARD, BOLT, null, rules)
		shooter.free()
		await _ticks(30)
		if keeps:
			_check(target_hits.size() == 1 and target_hits[0].attacker == null and target_hits[0].effects.size() > 0,
					"with lands_without_source, a removed shooter's bolt still hits, with the effects it set off with")
		else:
			_check(target_hits.is_empty(), "without it, it lands nothing")
		await _free(target)


# (Pawns stay within the floor, x -200 to 200.) A shooter spawned through the session and despawned while its bolt flies: it lingers, hidden, frozen and not colliding, until the
# bolt ends, so the bolt's hit still has its ability, then goes the tick after.
func _test_linger() -> void:
	NetworkSession.register_type("hit_test_pawn", load(PAWN_SCENE))
	var shooter := NetworkSession.spawn("hit_test_pawn", 0, Vector3(-60, 0.1, 0)) as Pawn
	shooter.skip_default_parts = NO_AI
	var target := _pawn(Vector3(-60, 0.1, -12), 1)
	var target_hits := _hits_on(target)
	await _ticks(10)
	var melee: AbilityBase = shooter.ability_manager.get_node("MeleeAttack")
	var bolt := Projectile.fire(melee, Vector3(-60, 1.3, -0.5), Vector3.FORWARD, BOLT)
	var ends_at := bolt.launch_tick + bolt.end_tick
	var entity := shooter.get_network_entity()
	NetworkSession.despawn(entity.entity_id)
	await _ticks(2)
	_check(is_instance_valid(shooter) and not shooter.visible and shooter.is_frozen() and shooter.collision_layer == 0,
			"a pawn despawned while its bolt flies lingers: hidden, frozen, not colliding")
	await _ticks(25)
	_check(target_hits.size() == 1 and target_hits[0].ability == melee, "its bolt's hit still lands through its ability")
	while TickDriver.tick <= ends_at + 1:
		await get_tree().physics_frame
	await _ticks(2)
	_check(not is_instance_valid(shooter), "and it goes the tick after its bolt's end (tick %d)" % ends_at)
	await _free(target)


# Claude 2026-11-22 (the owner): the world blocks a swing along the weapon's reach, not from the chest. A thin wall between attacker and
# target blocks it; a low crate in front of the attacker, under the swing's height, doesn't.
func _test_melee_walls() -> void:
	for case: String in ["wall", "crate"]:
		var x := -100.0 if case == "wall" else -120.0
		var attacker := _pawn(Vector3(x, 0.1, 0), 0)
		var target := _pawn(Vector3(x, 0.1, -1.3), 1)
		var target_hits := _hits_on(target)
		var block := _box(Vector3(x, 1.0, -0.65), Vector3(3, 2, 0.1)) if case == "wall" else _box(Vector3(x, 0.3, -0.65), Vector3(3, 0.6, 0.1))
		await _ticks(10)
		var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
		var met: Array = []
		melee.intersected.connect(func(entry: Dictionary) -> void: met.append(entry))
		await _swing(attacker, melee)
		if case == "wall":
			_check(target_hits.is_empty() and not met.is_empty() and met[0].blocked, "a wall between attacker and target blocks the swing, and its log says so")
		else:
			_check(target_hits.size() == 1, "a low crate under the swing's height doesn't block it")
		block.free()
		await _free(attacker, target)


# Claude 2026-11-22: walls a shot goes through are on a physics layer its world_mask leaves out; a wall on a layer it includes stops it.
func _test_wall_layers() -> void:
	var shooter := _pawn(Vector3(-160, 0.1, 0), 0)
	await _ticks(10)
	var thin := _box(Vector3(-160, 1.5, -5), Vector3(4, 4, 0.2))
	thin.collision_layer = 1 << 4 # layer 5: "thin cover", left out of the bolt's mask (1)
	var solid := _box(Vector3(-160, 1.5, -12), Vector3(4, 4, 0.5))
	await _ticks(2)
	var melee: AbilityBase = shooter.ability_manager.get_node("MeleeAttack")
	var bolt := Projectile.fire(melee, Vector3(-160, 1.3, -0.5), Vector3.FORWARD, BOLT)
	_check(absf(bolt.end_point.z - (-11.75)) < 0.01, "a bolt goes through a wall on a layer its world_mask leaves out, and stops at one it includes (z %.2f)" % bolt.end_point.z)
	var armour_piercing: ProjectileDefinition = BOLT.duplicate()
	armour_piercing.world_mask = 1 | (1 << 4)
	var stopped := Projectile.fire(melee, Vector3(-160, 1.3, -0.5), Vector3.FORWARD, armour_piercing)
	_check(absf(stopped.end_point.z - (-4.9)) < 0.01, "a variant whose mask includes that layer stops at the thin wall (z %.2f)" % stopped.end_point.z)
	await _ticks(30)
	thin.free()
	solid.free()
	await _free(shooter)


func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	add_child(body)
	return body


# The end a ray every tick would find, for comparing.
func _trace_end(projectile: Projectile) -> Array:
	var ray := PhysicsRayQueryParameters3D.new()
	ray.collision_mask = projectile.flight().world_mask
	for age in range(1, projectile.flight().lifetime_ticks() + 1):
		ray.from = projectile.position_at(age - 1)
		ray.to = projectile.position_at(age)
		var found := projectile.get_world_3d().direct_space_state.intersect_ray(ray)
		if not found.is_empty():
			return [age, found["position"]]
	return [-1, Vector3.ZERO]


# Starts a swing and waits for it to end and its cooldown.
func _swing(attacker: Pawn, melee: MeleeAttackAbility) -> void:
	melee.ready_at = 0
	attacker.ability_manager.start_ability(melee)
	for i in 60:
		if not melee.is_running_timed():
			break
		await get_tree().physics_frame
	await _ticks(2)


func _hits_on(pawn: Pawn) -> Array:
	var hits := []
	pawn.ability_manager.hit_received.connect(func(hit: HitInfo) -> void: hits.append(hit))
	return hits


func _pawn(at: Vector3, team: int) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.team = team
	pawn.position = at
	add_child(pawn)
	return pawn


func _flat_at(degrees: float, distance: float) -> Vector3:
	var angle := deg_to_rad(degrees)
	return Vector3(-sin(angle), 0.0, -cos(angle)) * distance


func _floor() -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)


func _free(...nodes: Array) -> void:
	for node: Node in nodes:
		node.queue_free()
	await _ticks(2)


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
