## Written by Claude (claude-opus-5-5), 2026-11-18: headless self-test for projectiles and the ranged attack (pawn spec 8.24), offline.
## A shot lands once (bolt_hit: 15 damage) and the bolt despawns; a miss flies its range and despawns; a wall stops it; it flies through
## its own team; a parry turns it away; a dashing (invulnerable) pawn is flown through; gravity bends it; a bolt outlives its shooter;
## an AI goblin with its melee behaviours removed shoots its target from range; and a whole AI goblin hangs back at shooting distance,
## backs away from a target too close, and melees one within its melee distance. -- --only=<part> --verbose traces one part.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/abilities/tests/projectile_selftest.tscn"
extends SelfTest

# The faction samples' pawns: their abilities (faction_abilities.tscn) include RangedAttack on ability_3, firing the bolt (bolt.tres; bolt.tscn until 2026-11-22).
const PAWN_SCENE := "res://assets/scenes/samples/faction_player.tscn"
const GOBLIN_SCENE := "res://assets/scenes/samples/faction_goblin.tscn"
const BOLT := preload("res://assets/scripts/resources/abilities/bolt.tres") # Claude 2026-11-22: a definition flown by the built-in projectile, was bolt.tscn
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]
const MELEE_BEHAVIOURS: Array[StringName] = [&"Attack", &"HeavyAttack"]


func _ready() -> void:
	print("--- Projectile self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	Projectile.register()
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(800, 1, 800)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	# -- --only=<name> runs one part (hit, miss, wall, own_team, parry, dash, gravity, shooter_gone, pierce, whitelist, speed_curve, hooks, predicted,
	# ai_shoots, keep_distance), for chasing a failure.
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	for part: String in ["hit", "miss", "wall", "own_team", "parry", "dash", "gravity", "shooter_gone", "pierce", "whitelist", "speed_curve", "hooks", "predicted", "ai_shoots", "keep_distance"]:
		if only == "" or only == part:
			await call("_test_" + part)
	_finish()


# A shooter facing -Z (yaw 0) and a target 8 m ahead: one shot, one hit, 15 damage, and the bolt is gone.
func _test_hit() -> void:
	var shooter := _make_pawn(Vector3(0, 0.1, 0), 0)
	var target := _make_pawn(Vector3(0, 0.1, -8), 1)
	await _ticks(10)
	var ranged := _ranged_of(shooter)
	_check(ranged != null and ranged.trigger_action == &"ability_3" and ranged.projectile_definition == BOLT and ranged.attack_reach() > 10.0,
		"the faction pawns have RangedAttack on ability_3, firing the bolt, with an AI reach (%.0f m)" % (ranged.attack_reach() if ranged else 0.0))
	var hits := _count_hits(target)
	_check(shooter.ability_manager.start_ability(ranged), "it starts")
	var waited := 0
	while _bolts().is_empty() and waited < 40:
		await _ticks(1)
		waited += 1
	_check(_bolts().size() == 1 and waited >= 12, "after the windup (12 ticks, the shot came at %d), one bolt is flying" % waited)
	var bolt: Projectile = _bolts()[0] if not _bolts().is_empty() else null
	_check(bolt != null and bolt.shooter == shooter and bolt.team == 0 and bolt.velocity.z < -29.0,
		"it's the shooter's, on its team, flying at 30 m/s along its look")
	await _ticks(30)
	_check(hits.size() == 1 and hits[0].ability == ranged, "it hits the target once (%d hits), carrying the ability" % hits.size())
	_check_equal(target.stat_manager.get_health(), 85.0, "bolt_hit takes 15 Health")
	_check(_bolts().is_empty(), "and the bolt is gone")
	await _free(shooter, target)


# Nothing in the way: it flies its max_range (40 m at 30 m/s, about 80 ticks) and despawns.
func _test_miss() -> void:
	var shooter := _make_pawn(Vector3(40, 0.1, 0), 0)
	await _ticks(10)
	shooter.ability_manager.start_ability(_ranged_of(shooter))
	while _bolts().is_empty():
		await _ticks(1)
	var bolt: Projectile = _bolts()[0]
	var start := bolt.global_position
	var furthest := 0.0
	var flew := 0
	while is_instance_valid(bolt) and not bolt.is_queued_for_deletion() and flew < 200:
		furthest = maxf(furthest, start.distance_to(bolt.global_position))
		flew += 1
		await _ticks(1)
	_check(flew < 200, "a bolt that hits nothing despawns (after %d ticks)" % flew)
	_check(furthest > 37.0 and furthest <= 40.5, "after its range (%.1f m of 40)" % furthest)
	await _free(shooter)


# A wall between: the bolt stops at it, and the target behind is untouched.
func _test_wall() -> void:
	var shooter := _make_pawn(Vector3(80, 0.1, 0), 0)
	var target := _make_pawn(Vector3(80, 0.1, -8), 1)
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 0.5)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(80, 2, -4)
	add_child(wall)
	await _ticks(10)
	shooter.ability_manager.start_ability(_ranged_of(shooter))
	await _ticks(50)
	_check_equal(target.stat_manager.get_health(), 100.0, "a wall stops the bolt: the target behind it is untouched")
	_check(_bolts().is_empty(), "and the bolt is gone")
	wall.queue_free()
	await _free(shooter, target)


# A teammate in the line of fire is flown through; the enemy behind is hit.
func _test_own_team() -> void:
	var shooter := _make_pawn(Vector3(120, 0.1, 0), 0)
	var friend := _make_pawn(Vector3(120, 0.1, -4), 0)
	var enemy := _make_pawn(Vector3(120, 0.1, -9), 1)
	await _ticks(10)
	shooter.ability_manager.start_ability(_ranged_of(shooter))
	await _ticks(50)
	_check_equal(friend.stat_manager.get_health(), 100.0, "a bolt flies through its own team")
	_check_equal(enemy.stat_manager.get_health(), 85.0, "and hits the enemy behind")
	await _free(shooter, friend, enemy)


# A target facing the shooter and parrying: the bolt is turned away (no damage) and hit_intercepted goes out.
func _test_parry() -> void:
	var shooter := _make_pawn(Vector3(160, 0.1, 0), 0)
	var target := _make_pawn(Vector3(160, 0.1, -6), 1)
	await _ticks(10)
	target.yaw = PI # facing +Z, toward the shooter
	target.controller_manager.look_yaw = PI
	var parried := []
	target.ability_manager.hit_intercepted.connect(func(hit: HitInfo, _by: HitInterceptor) -> void: parried.append(hit))
	shooter.ability_manager.start_ability(_ranged_of(shooter))
	await _ticks(14) # the shot is out; it arrives about 10 ticks later
	target.ability_manager.start_ability(_parry_of(target))
	await _ticks(30)
	_check(parried.size() == 1 and target.stat_manager.get_health() == 100.0,
		"a parry from the front turns a bolt away (%d parried, Health %d)" % [parried.size(), target.stat_manager.get_health()])
	await _free(shooter, target)


# A dash is invulnerable for its first 0.18 s: a bolt fired into a dashing pawn flies through it.
func _test_dash() -> void:
	var shooter := _make_pawn(Vector3(200, 0.1, 0), 0)
	var target := _make_pawn(Vector3(200, 0.1, -3), 1)
	await _ticks(10)
	var dash: AbilityBase = target.ability_manager.get_node("Dash")
	_check(target.ability_manager.start_ability(dash), "the target dashes")
	await _ticks(1)
	_check(target.ability_manager.is_invulnerable(), "and is invulnerable")
	Projectile.fire(_ranged_of(shooter), shooter.global_position + Vector3(0, 1.3, -0.5), Vector3.FORWARD, BOLT)
	await _ticks(8)
	_check_equal(target.stat_manager.get_health(), 100.0, "a bolt flies through a dashing pawn")
	await _ticks(60)
	await _free(shooter, target)


# With gravity, a bolt fired level drops about g t^2 / 2.
func _test_gravity() -> void:
	var shooter := _make_pawn(Vector3(240, 0.1, 0), 0)
	await _ticks(10)
	var heavy: ProjectileDefinition = BOLT.duplicate() # Claude 2026-11-22: gravity is a share of the world's now (gravity_scale)
	heavy.gravity_scale = 1.0
	var bolt := Projectile.fire(_ranged_of(shooter), Vector3(240, 5, -1), Vector3.FORWARD, heavy)
	var start_y := bolt.global_position.y
	await _ticks(20) # a third of a second: about 0.54 m
	var dropped := start_y - bolt.global_position.y if is_instance_valid(bolt) else -1.0
	_check(dropped > 0.4 and dropped < 0.7, "with gravity 9.8 it drops (%.2f m in 20 ticks, about 0.54 wanted)" % dropped)
	_check(is_instance_valid(bolt) and bolt.velocity.y < -2.0, "and its velocity bends down (%.1f m/s)" % (bolt.velocity.y if is_instance_valid(bolt) else 0.0))
	await _ticks(120)
	await _free(shooter)


# The shooter freed while its bolt flies: the bolt flies on without crashing (it once handed the freed shooter to the C++ grid) and meets
# its target, but lands no hit.
func _test_shooter_gone() -> void:
	var shooter := _make_pawn(Vector3(320, 0.1, 0), 0)
	var target := _make_pawn(Vector3(320, 0.1, -12), 1)
	await _ticks(10)
	var bolt := Projectile.fire(_ranged_of(shooter), shooter.global_position + Vector3(0, 1.3, -0.5), Vector3.FORWARD, BOLT)
	var met: Array = []
	bolt.intersected.connect(func(_p: Projectile, entry: Dictionary) -> void: met.append([entry.target, entry.hit]))
	await _free(shooter)
	await _ticks(30)
	# Claude 2026-11-22 (ability spec 13.5, the owner's call): a hit needs its ability, so a removed shooter's bolt meets the target
	# but lands nothing. It was "still lands" before.
	_check(met == [[target, false]] and is_equal_approx(target.stat_manager.get_health(), 100.0),
			"a bolt whose shooter is gone flies on and meets its target, but lands no hit (%s)" % str(met))
	await _free(target)


# An AI goblin with its melee behaviours removed (the projectile tests turn melee off): it shoots its target from range, and every hit
# is a bolt.
func _test_ai_shoots() -> void:
	var goblin: Pawn = load(GOBLIN_SCENE).instantiate()
	goblin.team = 2
	goblin.position = Vector3(360, 0.1, 0)
	var behaviours := goblin.get_node("AIBehaviourManager")
	for behaviour_name in MELEE_BEHAVIOURS:
		var behaviour := behaviours.get_node_or_null(NodePath(behaviour_name))
		if behaviour:
			behaviours.remove_child(behaviour)
			behaviour.free()
	add_child(goblin)
	var target := _make_pawn(Vector3(360, 0.1, -10), 1)
	await _ticks(10)
	var hits := _count_hits(target)
	var verbose := OS.get_cmdline_user_args().has("--verbose")
	if verbose:
		goblin.ability_manager.ability_started.connect(func(ability: AbilityBase) -> void:
			if ability is RangedAttackAbility:
				print("    shot starts: yaw %.2f look_yaw %.2f pitch %.2f, to target %s" % [goblin.yaw, goblin.controller_manager.look_yaw,
					goblin.controller_manager.look_pitch, target.global_position - goblin.global_position]))
		goblin.ability_manager.ability_cancelled.connect(func(ability: AbilityBase, by: AbilityBase) -> void:
			print("    %s cancelled by %s at %d" % [ability.name, by.name if by else "-", TickDriver.tick]))
		goblin.ability_manager.step_finished.connect(func(ability: AbilityBase, step: AbilityStep, reason: String) -> void:
			print("    %s/%s %s at %d" % [ability.name, step.name, reason, TickDriver.tick]))
		goblin.ability_manager.ability_finished.connect(func(ability: AbilityBase) -> void:
			print("    %s finished at %d" % [ability.name, TickDriver.tick]))
		NetworkSession.entity_spawned.connect(func(entity: NetworkEntity) -> void:
			var node := entity.get_parent()
			print("    spawned %s at %s under %s, tick %d" % [node.name, node.get("global_position"), node.get_parent().name, TickDriver.tick]))
		NetworkSession.entity_despawned.connect(func(entity_id: int) -> void: print("    despawned %d at tick %d" % [entity_id, TickDriver.tick]))
	var last_seen := {}
	for second in 10:
		for t in 60:
			await _ticks(1)
			if verbose:
				var now := {}
				for bolt in _bolts():
					now[bolt] = [bolt.global_position, bolt.velocity]
				for bolt: Variant in last_seen:
					if not now.has(bolt):
						print("    bolt ended at %s, velocity %s; target at %s" % [last_seen[bolt][0], last_seen[bolt][1], target.global_position])
				last_seen = now
		if OS.get_cmdline_user_args().has("--verbose"):
			var running: AIBehaviourBase = goblin.get_node("AIBehaviourManager").get_running_behaviour()
			print("    t=%d state=%s target=%s running=%s dist=%.1f" % [second, goblin.ai_context.current_state_name(),
				goblin.ai_context.current_target, running.name if running else "-", goblin.global_position.distance_to(target.global_position)])
			for bolt in _bolts():
				print("    bolt at %s velocity %s launched %s done %s" % [bolt.global_position, bolt.velocity, bolt._launched, bolt.is_done()])
			var shoot: AIBehaviourBase = goblin.get_node("AIBehaviourManager/Shoot")
			var condition: Variant = shoot.all_conditions()[0] if not shoot.all_conditions().is_empty() else null
			print("    shoot conditions=%s threshold=%s can_start=%s" % [shoot.all_conditions().size(), condition.get("value") if condition else "-",
				goblin.ability_manager.can_start(&"ability_3")])
	var by_bolt := hits.filter(func(hit: HitInfo) -> bool: return hit.ability is RangedAttackAbility)
	_check(by_bolt.size() >= 2, "an AI goblin shoots its target (%d bolt hits in 10 s, Health %d)" % [by_bolt.size(), target.stat_manager.get_health()])
	_check(by_bolt.size() == hits.size(), "with melee off, every hit is a bolt (%d of %d)" % [by_bolt.size(), hits.size()])
	await _free(goblin, target)


# A whole AI goblin (melee on): it closes from 18 m to its Keep Distance spot and shoots; it backs away from a target placed too close
# for comfort; and it melees a target within melee_distance instead of shooting it.
func _test_keep_distance() -> void:
	var goblin: Pawn = load(GOBLIN_SCENE).instantiate()
	goblin.team = 2
	goblin.position = Vector3(-360, 0.1, 0)
	add_child(goblin)
	var keep: AIKeepDistanceBehaviour = goblin.get_node("AIBehaviourManager/KeepDistance")
	var target := _make_pawn(Vector3(-360, 0.1, -10), 1) # close enough to be seen quickly: sight fills slower with distance
	var health := target.stat_manager.get_stat(&"Health")
	health.base_value = 100000.0 # never dies here
	health.current = 100000.0
	var hits := _count_hits(target)
	var preferred := keep.preferred_distance()
	_check(keep.find_ranged_attack() is RangedAttackAbility and is_equal_approx(preferred, 14.0 * 0.7),
		"Keep Distance finds the goblin's ranged attack by its tag and stands at 0.7 of its reach (%.1f m)" % preferred)
	# It sees the target and starts the fight; then the target steps out to 18 m: it closes in, holds its distance and shoots.
	await _watch(goblin, target, 120)
	hits.clear()
	target.global_position = goblin.global_position + _toward(goblin, target) * 18.0
	var ran := await _watch(goblin, target, 360)
	var distance := _flat_distance(goblin, target)
	_check(ran.has(&"KeepDistance") and absf(distance - preferred) <= keep.band + 0.5,
		"from 18 m it closes to its distance and holds it (%.1f m, ran %s)" % [distance, ran.keys()])
	var bolts := hits.filter(func(hit: HitInfo) -> bool: return hit.ability is RangedAttackAbility)
	var swings := hits.filter(func(hit: HitInfo) -> bool: return hit.ability is MeleeAttackAbility)
	_check(bolts.size() >= 2 and swings.is_empty(), "and shoots from there, never swinging (%d bolt hits, %d melee)" % [bolts.size(), swings.size()])
	# Too close for comfort, though not melee close: it backs off to its distance.
	target.global_position = goblin.global_position + _toward(goblin, target) * 6.0
	await _watch(goblin, target, 240)
	distance = _flat_distance(goblin, target)
	_check(absf(distance - preferred) <= keep.band + 0.5, "a target 6 m away: it backs off to its distance again (%.1f m)" % distance)
	# Within melee distance: Chase and the melee attacks take over, and it stops shooting. A shot already under way finishes (attacks
	# aren't cut off), so counting starts once it has landed.
	target.global_position = goblin.global_position + _toward(goblin, target) * 2.0
	await _watch(goblin, target, 45, true)
	hits.clear()
	ran = await _watch(goblin, target, 180, true)
	bolts = hits.filter(func(hit: HitInfo) -> bool: return hit.ability is RangedAttackAbility)
	swings = hits.filter(func(hit: HitInfo) -> bool: return hit.ability is MeleeAttackAbility)
	_check(not swings.is_empty() and bolts.is_empty(), "a target 2 m away is met with melee, not bolts (%d melee hits, %d bolt hits, ran %s)" % [swings.size(),
		bolts.size(), ran.keys()])
	await _free(goblin, target)


# Runs ticks; pinned keeps the target within melee reach of the goblin (knockback pushes it off). Returns the behaviours that ran, by name.
func _watch(goblin: Pawn, target: Pawn, ticks: int, pinned := false) -> Dictionary:
	var ran := {}
	var verbose := OS.get_cmdline_user_args().has("--verbose")
	for t in ticks:
		await _ticks(1)
		if pinned and target.global_position.distance_to(goblin.global_position) > 2.0:
			target.global_position = goblin.global_position + _toward(goblin, target) * 1.5 # knockback pushes it off; keep it close
		var running: AIBehaviourBase = goblin.get_node("AIBehaviourManager").get_running_behaviour()
		if running:
			ran[running.name] = true
		if verbose and t % 30 == 0:
			print("    t=%d running=%s dist=%.1f" % [t, running.name if running else "-", _flat_distance(goblin, target)])
	return ran


func _flat_distance(a: Node3D, b: Node3D) -> float:
	return Vector2(a.global_position.x - b.global_position.x, a.global_position.z - b.global_position.z).length()


func _toward(from: Node3D, to: Node3D) -> Vector3:
	var offset := to.global_position - from.global_position
	offset.y = 0.0
	return offset.normalized() if offset.length_squared() > 0.0001 else Vector3.FORWARD


# Claude 2026-11-22 (ability spec 9): max_hits. Kept within the floor (x -400 to 400). Three targets in a row: 2 stops in the second, 0 passes through all, each hit once.
func _test_pierce() -> void:
	for max_hits: int in [2, 0]:
		var shooter := _make_pawn(Vector3(-100 - max_hits * 40, 0.1, 0), 0)
		var targets: Array[Pawn] = []
		var hits: Array = []
		for z: float in [-6.0, -9.0, -12.0]:
			var target := _make_pawn(Vector3(-100 - max_hits * 40, 0.1, z), 1)
			targets.append(target)
			hits.append(_count_hits(target))
		await _ticks(10)
		var piercing := HitDefinition.new() # Claude 2026-11-22 (ability spec 13): max_hits is the hit definition's
		piercing.max_hits = max_hits
		var bolt := Projectile.fire(_ranged_of(shooter), shooter.global_position + Vector3(0, 1.3, -0.5), Vector3.FORWARD, BOLT, null, piercing)
		await _ticks(40)
		var counts: Array = hits.map(func(list: Array) -> int: return list.size())
		if max_hits == 2:
			_check(counts == [1, 1, 0] and not is_instance_valid(bolt), "max_hits 2: it hits the first two, once each, and stops in the second (%s)" % str(counts))
		else:
			_check(counts == [1, 1, 1], "max_hits 0: it passes through all three, hitting each once (%s)" % str(counts))
		await _free(shooter, targets[0], targets[1], targets[2])


# Claude 2026-11-22: the whitelist and the intersect log. An ally then an enemy in its path: by default the ally is met but not hit, the
# enemy hit; with hits_allies both are hit; with max_intersects 1 it ends at the ally.
func _test_whitelist() -> void:
	var cases := [["default", {}], ["allies", {"hits_allies": true}], ["one intersect", {"max_intersects": 1, "max_hits": 0}]]
	for i in cases.size():
		var x := -150.0 - i * 30.0
		var shooter := _make_pawn(Vector3(x, 0.1, 0), 0)
		var ally := _make_pawn(Vector3(x, 0.1, -6), 0)
		var enemy := _make_pawn(Vector3(x, 0.1, -10), 1)
		var ally_hits := _count_hits(ally)
		var enemy_hits := _count_hits(enemy)
		await _ticks(10)
		var rules := HitDefinition.new() # Claude 2026-11-22 (ability spec 13): the whitelist and limits are the hit definition's
		for key: String in cases[i][1]:
			rules.set(key, cases[i][1][key])
		var bolt := Projectile.fire(_ranged_of(shooter), Vector3(x, 1.3, -0.5), Vector3.FORWARD, BOLT, null, rules)
		var log: Array = []
		bolt.intersected.connect(func(_p: Projectile, entry: Dictionary) -> void: log.append([entry.target, entry.hit]))
		await _ticks(30)
		match cases[i][0]:
			"default":
				_check(log.size() >= 2 and log[0] == [ally, false] and log[1] == [enemy, true] and ally_hits.is_empty() and enemy_hits.size() == 1,
						"by default it meets the ally without hitting it, and hits the enemy; both are logged (%d)" % log.size())
			"allies":
				_check(ally_hits.size() == 1 and enemy_hits.size() == 1, "with hits_allies it hits both")
			_:
				_check(log.size() == 1 and enemy_hits.is_empty(), "with max_intersects 1 it ends at the first thing it meets, hit or not")
		await _free(shooter, ally, enemy)


# Claude 2026-11-22: a speed curve from 1 down to 0 over its 3 s life. After 1 s it has flown 30 m x (1 - 1/6) = 25 m, not 30; and its
# launch record doesn't change in flight, so nothing about it is sent while it flies.
func _test_speed_curve() -> void:
	var shooter := _make_pawn(Vector3(-220, 0.1, 0), 0)
	await _ticks(10)
	var slowing: ProjectileDefinition = BOLT.duplicate()
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	curve.add_point(Vector2(1.0, 0.0), 0.0, 0.0, Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	slowing.speed_curve = curve
	var origin := Vector3(-220, 5, -1)
	var bolt := Projectile.fire(_ranged_of(shooter), origin, Vector3.FORWARD, slowing)
	await _ticks(1) # the first record rounds the values (StateEncoding); from then on they don't change
	var record := [bolt.launch_tick, bolt.launch_origin, bolt.launch_direction]
	await _ticks(10)
	# GDScript note: compared one by one; two arrays holding equal vectors can still compare unequal (a -0.0 against a 0.0).
	_check(is_instance_valid(bolt) and bolt.launch_tick == record[0] and bolt.launch_origin == record[1] and bolt.launch_direction == record[2],
		"its launch record stays the same in flight")
	await _ticks(49)
	var flown := origin.distance_to(bolt.global_position) if is_instance_valid(bolt) else -1.0
	_check(absf(flown - 25.0) < 0.6, "a speed curve slows it: %.1f m in 1 s, about 25 wanted" % flown)
	_check(is_instance_valid(bolt) and bolt.velocity.length() < 21.0, "and its speed now is lower (%.1f m/s)" % (bolt.velocity.length() if is_instance_valid(bolt) else 0.0))
	await _ticks(130)
	await _free(shooter)


# Claude 2026-11-22: the visual hooks (launched, hit_pawn, ended), the impact scene where it ends, and the same hit path as a swing
# (the ability's hit_landed).
func _test_hooks() -> void:
	var shooter := _make_pawn(Vector3(-260, 0.1, 0), 0)
	var target := _make_pawn(Vector3(-260, 0.1, -8), 1)
	await _ticks(10)
	var spark := Node3D.new()
	spark.name = "Spark"
	var packed := PackedScene.new()
	packed.pack(spark)
	spark.free()
	var sparking: ProjectileDefinition = BOLT.duplicate()
	sparking.impact_scene = packed
	var heard := {"launched": 0, "hit_pawn": null, "ended": null, "hit_landed": 0}
	var ranged := _ranged_of(shooter)
	ranged.hit_landed.connect(func(_hit: HitInfo) -> void: heard.hit_landed += 1)
	var trace := ProjectileTraceView.new() # the diagnostics' F5 view, shown here directly
	add_child(trace)
	trace.set_shown(true)
	var bolt := NetworkSession.spawn(Projectile.TYPE, 0, Vector3(-260, 1.3, -0.5)) as Projectile
	bolt.launched.connect(func(_p: Projectile) -> void: heard.launched += 1)
	bolt.hit_pawn.connect(func(_p: Projectile, who: Pawn, _at: Vector3) -> void: heard.hit_pawn = who)
	bolt.ended.connect(func(_p: Projectile, at: Vector3) -> void: heard.ended = at)
	bolt.launch(ranged, Vector3(-260, 1.3, -0.5), Vector3.FORWARD, sparking)
	_check(bolt.get_node_or_null(^"Visual") != null, "the built-in projectile takes its look from its definition's visual scene")
	await _ticks(20)
	var spark_at: Node3D = null
	for child in bolt.get_parent().get_children() if is_instance_valid(bolt) else get_children():
		if child.name.begins_with("Spark"):
			spark_at = child
	if spark_at == null:
		for child in NetworkSession.world_root.get_children() if NetworkSession.world_root else get_children():
			if String(child.name).begins_with("Spark"):
				spark_at = child
	_check(heard.launched == 1 and heard.hit_pawn == target and heard.ended != null, "its hooks: launched, hit_pawn (the target), then ended")
	_check(heard.hit_landed == 1, "and its ability hears hit_landed, as a swing's does (one shared hit path)")
	_check(spark_at != null and spark_at.global_position.distance_to(heard.ended) < 0.01, "its impact scene shows where it ended")
	var traced: Array = trace._traces.values()
	_check(traced.size() == 1 and traced[0].plan.size() > 2 and traced[0].marks.size() == 1 and traced[0].end != null,
			"the F5 trace has its planned path, the intersect and the end")
	trace.free()
	await _free(shooter, target)


# Claude 2026-11-22: the shooter's predicted copy flies from the same launch and goes when the server's shot ends.
func _test_predicted() -> void:
	var shooter := _make_pawn(Vector3(-320, 0.1, 0), 0)
	await _ticks(10)
	var tick: int = TickDriver.tick
	var copy := PredictedProjectile.fire(BOLT, null, shooter, Vector3(-320, 1.3, -0.5), Vector3.FORWARD, tick)
	await _ticks(6)
	_check(copy != null and is_instance_valid(copy) and copy.global_position.z < -2.0, "a predicted copy flies at once, drawn from the launch (z %.1f)" % (copy.global_position.z if copy else 0.0))
	var entity := shooter.get_network_entity()
	PredictedProjectile.server_shot_ended(entity.entity_id if entity else -1, tick)
	await _ticks(2)
	_check(not is_instance_valid(copy), "and goes when the server's shot ends")
	await _free(shooter)


func _ranged_of(pawn: Pawn) -> RangedAttackAbility:
	for ability in pawn.ability_manager.get_abilities():
		if ability is RangedAttackAbility:
			return ability
	return null


func _parry_of(pawn: Pawn) -> ParryAbility:
	for ability in pawn.ability_manager.get_abilities():
		if ability is ParryAbility:
			return ability
	return null


# Every hit that lands on pawn from now, as a list that fills as they come.
func _count_hits(pawn: Pawn) -> Array:
	var hits := []
	pawn.ability_manager.hit_received.connect(func(hit: HitInfo) -> void: hits.append(hit))
	return hits


func _bolts() -> Array[Projectile]:
	var found: Array[Projectile] = []
	for child in get_children():
		if child is Projectile and not child.is_queued_for_deletion():
			found.append(child)
	return found


func _make_pawn(at: Vector3, team: int) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.team = team
	pawn.position = at
	add_child(pawn)
	return pawn


func _free(...pawns: Array) -> void:
	for pawn: Node in pawns:
		pawn.queue_free()
	await _ticks(2)


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
