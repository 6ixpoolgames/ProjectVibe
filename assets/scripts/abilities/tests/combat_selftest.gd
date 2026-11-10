## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for pawn spec step 9: Dash, MeleeAttack, Knockback, the
## interrupt rules (pawn spec 8.6), hits on the server only, rollback, the lag compensation input, and the AI's Attack behaviour.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/abilities/tests/combat_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


## A timed action a test can give any threshold, locking out walking, sprinting and jumping, like an emote or a reload.
class Busy extends AbilityBase:
	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"secondary"
		category = &"utility.interact"
		duration = 2.0
		locks_out = [&"movement.walk", &"movement.sprint", &"movement.jump"]


func _ready() -> void:
	# Claude 2026-11-09 (scaling spec step 6): these checks count exact ticks at the reference rate, 60 a second, so they pin it, even
	# in a run at another rate (-- --tick-rate=30). tick_rate_selftest checks that converted settings last the same time at 30.
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- Combat self-test ---")
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_dash()
	await _test_interrupts()
	await _test_tag_groups() # Claude 2026-11-10
	await _test_interrupt_table() # Claude 2026-11-10
	await _test_melee_hits()
	await _test_melee_multi_hit() # Claude 2026-11-09
	await _test_hits_after_simulate() # Claude 2026-11-09
	await _test_server_only_and_replays()
	_test_view_ticks_behind()
	await _test_ai_attacks()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_dash() -> void:
	var pawn := _make_pawn(Vector3(0, 0.1, 0))
	var ai := _ai(pawn)
	var dash: DashAbility = pawn.ability_manager.get_node("Dash")
	await _ticks(15)
	# Claude 2026-11-10, the owner's design: it speeds up at 100 m/s^2 for 0.1 s (+10 m/s), then slows down at 50 m/s^2 for 0.2 s
	# (-10 m/s), so it ends at the speed it started with. These checks replace the flat 18 m/s ones (a burst at DashSpeed, about 2.7 m).
	_check(dash.duration_ticks() == 18, "it lasts 18 ticks: 6 speeding up, 12 slowing down (%d)" % dash.duration_ticks())
	var start := pawn.global_position
	ai.move_in_direction(Vector3(1, 0, 0))
	ai.press(&"dash")
	var run := await _dash_run(pawn, dash, func(frame: int) -> void:
		if frame == 3:
			ai.press(&"jump"))
	var travelled := pawn.global_position.x - start.x
	_check(run["ticks"] >= 17 and run["peak"] > 9.5 and run["peak"] < 11.5 and run["end"] < 1.5, "from standing: up to about 10 m/s, then back down (peak %.1f, end %.1f m/s, %d ticks)" % [run["peak"], run["end"], run["ticks"]])
	_check(travelled > 1.3 and travelled < 2.0, "about 1.5 m (%.2f m)" % travelled)
	_check(run["max_y"] <= 0.01, "jump is locked out while dashing")
	ai.stop()
	await _until(func() -> bool: return dash.cooldown_ticks_left == 0, 150)
	# Walking at 5 m/s: up to about 15, then back to about 5. Walk doesn't slow it as well (pauses_locomotion).
	ai.move_in_direction(Vector3(1, 0, 0))
	await _ticks(30)
	var walking := pawn.velocity.x
	ai.press(&"dash")
	run = await _dash_run(pawn, dash)
	_check(walking > 4.8 and run["peak"] > 14.0 and run["peak"] < 16.0 and absf(run["end"] - walking) < 0.6, "walking: up to walking speed + 10, then back to it (%.1f, peak %.1f, end %.1f m/s)" % [walking, run["peak"], run["end"]])
	ai.stop()
	await _ticks(60)
	_check(Vector2(pawn.velocity.x, pawn.velocity.z).length() < 0.5, "and Walk takes over again after it")
	await _until(func() -> bool: return dash.cooldown_ticks_left == 0, 150)
	var facing_before := pawn.yaw
	ai.press(&"dash")
	await _ticks(2)
	var along := Vector3(-sin(facing_before), 0, -cos(facing_before))
	_check(Vector3(pawn.velocity.x, 0, pawn.velocity.z).normalized().dot(along) > 0.99, "standing still, it dashes the way it faces")
	await _until(func() -> bool: return not dash.is_running_timed() and dash.cooldown_ticks_left == 0, 150)
	await _ticks(30)
	# Claude 2026-11-10, the owner's call: an air dash now (it was "no air dash"), toward the input, not the way the pawn faces. And
	# speed gained some other way during it is kept at the end: the slow-down takes a fixed amount off, it doesn't aim at a speed.
	pawn.yaw = 0.0 # facing -Z
	ai.press(&"jump")
	await _ticks(3)
	ai.move_in_direction(Vector3(1, 0, 0))
	ai.press(&"dash")
	await _ticks(2)
	_check(dash.is_running_timed() and not pawn.grounded and pawn.velocity.x > 1.0 and absf(pawn.velocity.z) < 0.5, "an air dash, toward the input (+X), not the way it faced (-Z) (%.1f, %.1f m/s)" % [pawn.velocity.x, pawn.velocity.z])
	run = await _dash_run(pawn, dash, func(frame: int) -> void:
		if frame == 6:
			pawn.velocity.x += 3.0) # a push from something else, partway through
	_check(run["end"] > 2.4 and run["end"] < 3.6, "an extra 3 m/s found during the dash is still there when it ends (%.1f m/s)" % run["end"])
	ai.stop()
	ai.press(&"dash")
	await _ticks(2)
	_check(not dash.is_running_timed() and dash.cooldown_ticks_left > 0, "its cooldown stops a second dash straight after")
	dash.usable_in_air = false
	await _until(func() -> bool: return dash.cooldown_ticks_left == 0 and pawn.grounded, 150)
	ai.press(&"jump")
	await _ticks(3)
	ai.press(&"dash")
	await _ticks(2)
	_check(not dash.is_running_timed(), "with usable_in_air off: no air dash, as before")
	pawn.free()


# Claude 2026-11-10: several tags per ability (extra_categories), a lockout naming a group, and the AI's search by tag.
func _test_tag_groups() -> void:
	var pawn := _make_pawn(Vector3(50, 0.1, 0))
	var ai := _ai(pawn)
	var manager := pawn.ability_manager
	var dash: DashAbility = manager.get_node("Dash")
	await _ticks(15)
	var mask := dash.category_mask
	_check(TagRegistry.matches(mask, Tags.MOVEMENT_DASH) and TagRegistry.matches(mask, Tags.MOVEMENT_ADVANCED) and TagRegistry.matches(mask, Tags.MOVEMENT) and not TagRegistry.matches(mask, Tags.MOVEMENT_BASIC), "a dash answers to its category, its extra category (movement.advanced) and their parent, and not to basic movement")
	_check(manager.action_for_tag(Tags.MOVEMENT_ADVANCED) == &"dash", "asked for advanced movement, the manager answers with the action that starts the dash")
	_check(manager.action_for_tag(Tags.MOVEMENT_BASIC) == &"jump", "asked for basic movement: jump (walk and sprint are held, not pressed, so they're not offered)")
	_check(manager.action_for_tag(&"no.such.group") == &"" and not TagRegistry.has_tag(&"no.such.group"), "an unknown tag finds nothing, and isn't added to the registry")
	ai.press(&"dash")
	await _ticks(2)
	_check(dash.is_running_timed() and manager.action_for_tag(Tags.MOVEMENT_ADVANCED) == &"", "while the dash runs (or cools down), nothing in the group can start, so nothing is offered")
	_check(not manager.can_start(&"jump") and manager.action_for_tag(Tags.MOVEMENT_BASIC) == &"", "the dash locks out the basic movement group (locks_out [movement.basic]): jump can't start")
	pawn.free()


# Claude 2026-11-10: the interrupt table says what the rules do, by the pawn's numbers now.
func _test_interrupt_table() -> void:
	var listed := Busy.new()
	listed.name = "CancelledByJump"
	listed.cancelled_by = [Tags.MOVEMENT_JUMP]
	var pawn := _make_pawn(Vector3(60, 0.1, 0), [listed])
	var manager := pawn.ability_manager
	await _ticks(5)
	var rule := func(starting: String, running: String) -> String:
		return manager.interrupt_rule(manager.get_node(starting), manager.get_node(running))["result"]
	_check(rule.call("Dash", "MeleeAttack") == "cancels" and rule.call("Sprint", "MeleeAttack") == "blocked", "dash cancels a swing; sprint is blocked by one")
	_check(rule.call("Knockback", "Dash") == "cancels" and rule.call("Dash", "Knockback") == "cancels" and rule.call("MeleeAttack", "Knockback") == "blocked", "knockback and dash cancel each other; a swing can't break a knockback")
	_check(rule.call("Jump", "Dash") == "blocked" and rule.call("Jump", "Sprint") == "alongside", "a dash blocks a jump; a jump and a sprint run alongside")
	var listed_rule: Dictionary = manager.interrupt_rule(manager.get_node("Jump"), listed)
	_check(listed_rule["result"] == "cancels" and String(listed_rule["reason"]).contains("cancelled_by"), "cancelled_by shows, with its reason (%s)" % listed_rule["reason"])
	var melee: MeleeAttackAbility = manager.get_node("MeleeAttack")
	melee.interrupt_threshold = 50 # a berserk state, say: swings that can't be broken
	_check(rule.call("Dash", "MeleeAttack") == "blocked" and rule.call("Knockback", "MeleeAttack") == "blocked", "a threshold changed while playing shows at once: nothing below 50 breaks the swing")
	melee.interrupt_threshold = 15
	var table := manager.get_interrupt_table()
	var has_jump_row := table.any(func(row: Dictionary) -> bool: return row["running"] == &"Jump")
	_check(table.size() == manager.get_abilities().size() - 1 and not has_jump_row and table[0]["cells"].size() == manager.get_abilities().size() - 1, "a row per ability that can be running (not Jump, which happens at once), and an entry per other ability (%d rows)" % table.size())
	print(manager.get_interrupt_table_text().indent("      "))
	pawn.free()


# Claude 2026-11-10: a hit from in front, with a push and no damage worth noting, for the dash's invulnerability checks.
func _push_hit(pawn: Pawn) -> HitInfo:
	var hit := HitInfo.new()
	hit.target = pawn
	hit.direction = Vector3(-1, 0, 0)
	hit.effects = [Effect.make_knockback(8.0, 10)] # Claude 2026-11-10: hits carry effects now (pawn spec 8.11)
	return hit


# Claude 2026-11-10: follows a dash pressed this tick until it ends: its peak speed along its direction, its speed on the tick it ended,
# how many ticks it ran and the highest upward speed. during(frame) runs each frame, for a test to press something or push the pawn.
func _dash_run(pawn: Pawn, dash: DashAbility, during: Callable = Callable()) -> Dictionary:
	var out := {"peak": 0.0, "end": 0.0, "ticks": 0, "max_y": -INF}
	for frame in 40:
		await get_tree().physics_frame
		if not dash.is_running_timed():
			if out["ticks"] > 0:
				break
			continue
		out["ticks"] += 1
		out["peak"] = maxf(out["peak"], pawn.velocity.dot(dash.dash_direction))
		out["max_y"] = maxf(out["max_y"], pawn.velocity.y)
		if during.is_valid():
			during.call(frame)
	out["end"] = pawn.velocity.dot(dash.dash_direction)
	return out


func _test_interrupts() -> void:
	var pawn := _make_pawn(Vector3(10, 0.1, 0))
	var ai := _ai(pawn)
	var manager := pawn.ability_manager
	var melee: MeleeAttackAbility = manager.get_node("MeleeAttack")
	var dash: DashAbility = manager.get_node("Dash")
	var sprint: SprintAbility = manager.get_node("Sprint")
	var cancels := []
	manager.ability_cancelled.connect(func(what, by): cancels.append([what.name, by.name]))
	await _ticks(15)
	ai.press(&"primary")
	await _ticks(2)
	_check(melee.is_running_timed() and melee.ticks_left > 15, "the swing starts and lasts 24 ticks")
	ai.move_in_direction(Vector3(1, 0, 0))
	ai.hold(&"sprint")
	await _ticks(3)
	_check(melee.is_running_timed() and not sprint.is_running_timed(), "sprinting (10) doesn't cancel a swing (threshold 15)")
	_check(Vector2(pawn.velocity.x, pawn.velocity.z).length() < 0.5, "and the pawn holds still while swinging")
	ai.press(&"dash")
	await _ticks(2)
	_check(not melee.is_running_timed() and dash.is_running_timed(), "dash (40; Claude 2026-11-10: was 20) cancels the swing: the animation cancel")
	_check(cancels.has([&"MeleeAttack", &"Dash"]) and melee.cooldown_ticks_left >= 0, "ability_cancelled says so")
	ai.hold(&"sprint", false)
	ai.stop()
	await _ticks(30)
	# Claude 2026-11-10, the owner's calls: a dash is invulnerable for its first 0.18 s (11 ticks), so a hit then does nothing. After
	# that a hit lands, and its knockback (30) cancels the rest of the dash (threshold 25). A dash still cancels a knockback (below).
	await _until(func() -> bool: return dash.cooldown_ticks_left == 0, 150)
	var knockback: KnockbackAbility = manager.get_node("Knockback")
	ai.move_in_direction(Vector3(0, 0, 1))
	ai.press(&"dash")
	await _until(func() -> bool: return dash.is_running_timed(), 5)
	await _ticks(2)
	pawn.receive_hit(_push_hit(pawn))
	_check(dash.is_running_timed() and not knockback.is_running_timed() and pawn.is_invulnerable(), "early in a dash a hit does nothing: invulnerable (%d ticks in)" % dash.ticks_running())
	await _until(func() -> bool: return not pawn.is_invulnerable(), 20)
	var invulnerable_for := dash.ticks_running()
	_check(dash.is_running_timed() and invulnerable_for == 11, "invulnerable for the first 0.18 s, 11 ticks, then not, while the dash still runs (%d)" % invulnerable_for)
	pawn.receive_hit(_push_hit(pawn))
	_check(not dash.is_running_timed() and knockback.is_running_timed() and cancels.has([&"Dash", &"Knockback"]), "a hit after that lands, and its knockback (30) cancels the dash (threshold 25)")
	ai.stop()
	await _until(func() -> bool: return not knockback.is_running_timed() and not dash.is_running_timed() and dash.cooldown_ticks_left == 0, 150)
	_check(not pawn.is_invulnerable(), "and it isn't invulnerable once the dash is over")
	# cancelled_by: a test-only ability that jump can always cancel, though its threshold (100) is far above jump's priority (5).
	var cancelled_by_jump := Busy.new()
	cancelled_by_jump.name = "CancelledByJump"
	cancelled_by_jump.cancelled_by = [&"movement.jump"]
	var plain_busy := Busy.new()
	plain_busy.name = "PlainBusy"
	plain_busy.trigger_action = &"ability_2"
	var listed := _make_pawn(Vector3(40, 0.1, 0), [cancelled_by_jump, plain_busy])
	var listed_ai := _ai(listed)
	await _ticks(15)
	listed_ai.press(&"ability_2")
	await _ticks(2)
	listed_ai.press(&"jump")
	await _ticks(2)
	_check(plain_busy.is_running_timed() and listed.velocity.y <= 0.01, "without cancelled_by, jump (5) can't cancel a threshold of 100")
	listed.ability_manager.cancel(&"ability_2")
	# The jump pressed above waited in Jump's buffer and jumps now; let it land first.
	await _ticks(10)
	await _until(func() -> bool: return listed.grounded, 120)
	await _ticks(5)
	listed_ai.press(&"secondary")
	await _ticks(2)
	listed_ai.press(&"jump")
	await _ticks(2)
	_check(not cancelled_by_jump.is_running_timed() and listed.velocity.y > 1.0, "with cancelled_by [movement.jump], a jump cancels it and jumps (%.1f m/s up)" % listed.velocity.y)
	listed.free()
	knockback.push(Vector3(-8, 0, 0), 20)
	await _ticks(1)
	_check(knockback.is_running_timed() and pawn.velocity.x < -6.0, "a knockback pushes the pawn (%.1f m/s)" % pawn.velocity.x)
	ai.press(&"primary")
	ai.press(&"jump")
	await _ticks(2)
	_check(not melee.is_running_timed() and pawn.velocity.y <= 0.01, "attacking and jumping stay locked out while it's staggered")
	ai.move_in_direction(Vector3(0, 0, 1))
	ai.press(&"dash")
	await _ticks(2)
	_check(dash.is_running_timed() and not knockback.is_running_timed() and cancels.has([&"Knockback", &"Dash"]), "a dash (40) cancels the knockback (threshold 35)")
	ai.stop()
	await _ticks(30)
	_check(Vector2(pawn.velocity.x, pawn.velocity.z).length() < 0.5, "then the pawn slows to a stop")
	# Claude 2026-11-10, the owner's call: Dash works in the air now, so it breaks a knockback whose hop has lifted the pawn.
	await _until(func() -> bool: return dash.cooldown_ticks_left == 0 and pawn.grounded, 150)
	knockback.push(Vector3(-8, 0, 0), 20, 3.0)
	await _ticks(3)
	var hopping := not pawn.grounded
	ai.move_in_direction(Vector3(0, 0, 1))
	ai.press(&"dash")
	await _ticks(2)
	_check(hopping and dash.is_running_timed() and not knockback.is_running_timed(), "a dash breaks a knockback mid-hop (in the air: %s)" % hopping)
	ai.stop()
	pawn.free()

	# Thresholds 0 and 10, on an action that locks out movement: walking cancels the first, only sprinting the second.
	var emote := Busy.new()
	emote.name = "Emote"
	emote.interrupt_threshold = 0
	pawn = _make_pawn(Vector3(20, 0.1, 0), [emote])
	ai = _ai(pawn)
	await _ticks(15)
	ai.press(&"secondary")
	await _ticks(3)
	_check(emote.is_running_timed(), "an emote (threshold 0) starts")
	ai.move_in_direction(Vector3(1, 0, 0))
	await _ticks(3)
	_check(not emote.is_running_timed() and pawn.velocity.x > 1.0, "just moving cancels it")
	pawn.free()
	var reload := Busy.new()
	reload.name = "Reload"
	reload.interrupt_threshold = 10
	pawn = _make_pawn(Vector3(30, 0.1, 0), [reload])
	ai = _ai(pawn)
	await _ticks(15)
	ai.press(&"secondary")
	await _ticks(2)
	ai.move_in_direction(Vector3(1, 0, 0))
	await _ticks(5)
	_check(reload.is_running_timed(), "a reload (threshold 10) isn't cancelled by walking")
	ai.hold(&"sprint")
	await _ticks(3)
	_check(not reload.is_running_timed(), "but sprinting cancels it, like a CoD sprint cancel")
	pawn.free()


## Claude 2026-11-09: one swing hits every enemy inside its sphere, and each takes its own damage and its own knockback (the owner
## asked whether melee is multi-hit). Placed off to the side, at x = 30, away from the other tests' pawns.
func _test_melee_multi_hit() -> void:
	var attacker := _make_pawn(Vector3(30, 0.1, 40))
	attacker.team = 1
	# Both 1.4 m in front and 0.5 m to either side: inside the sphere (centre 1 m ahead, radius 0.8) and not touching each other.
	var left := _make_pawn(Vector3(29.5, 0.1, 38.6))
	var right := _make_pawn(Vector3(30.5, 0.1, 38.6))
	await _ticks(15)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var landed := []
	melee.hit_landed.connect(func(hit): landed.append(hit))
	var ai := _ai(attacker)
	ai.look_at_point(Vector3(30, 1, 30))
	await _ticks(2)
	ai.press(&"primary")
	await _ticks(16) # the 8-tick wind-up, the 4 hit ticks and the knockback's first ticks
	var hit_both := landed.any(func(hit): return hit.target == left) and landed.any(func(hit): return hit.target == right)
	_check(landed.size() == 2 and hit_both, "multi-hit: one swing hits both enemies inside its sphere, each once (%d hits)" % landed.size())
	# Claude 2026-11-10: the damage is the swing's on-hit effect now (swing_hit.tres, 20), not a number on the swing.
	var damage := -melee.on_hit_effects[0].planned_change(&"Health")
	_check(damage == 20.0 and left.get_health() == 100.0 - damage and right.get_health() == 100.0 - damage, "and each takes the damage from the swing's on-hit effect (%d and %d HP)" % [int(left.get_health()), int(right.get_health())])
	_check(left.global_position.x < 29.45 and right.global_position.x > 30.55, "and each is knocked back away from the attacker, to its own side (%.2f and %.2f m sideways)" % [left.global_position.x - 29.5, right.global_position.x - 30.5])
	attacker.free()
	left.free()
	right.free()


## Claude 2026-11-09 (pawn spec 15.4): hits are delivered after every pawn has simulated, so it doesn't matter whether the target
## simulates before or after its attacker. The same swing, with the two pawns joining the tick driver in both orders, must give the
## same result tick for tick. Placed at x = -30, away from the other tests' pawns.
func _test_hits_after_simulate() -> void:
	var results := []
	for attacker_first in [true, false]:
		var attacker: Pawn = null
		var target: Pawn = null
		if attacker_first:
			attacker = _make_pawn(Vector3(-30, 0.1, 40))
			target = _make_pawn(Vector3(-30, 0.1, 38.6))
		else:
			target = _make_pawn(Vector3(-30, 0.1, 38.6))
			attacker = _make_pawn(Vector3(-30, 0.1, 40))
		attacker.team = 1
		await _ticks(15)
		# GDScript note: a lambda can't change a plain local it captured, so what it records goes into an array.
		var seen := []
		attacker.ability_manager.get_node("MeleeAttack").hit_landed.connect(func(_hit): seen.append(["landed", TickDriver.tick]))
		target.hit_received.connect(func(_hit): seen.append(["received", TickDriver.tick, TickDriver.is_in_simulate()]))
		var ai := _ai(attacker)
		ai.look_at_point(Vector3(-30, 1, 30))
		await _ticks(2)
		var pressed_at: int = TickDriver.tick
		ai.press(&"primary")
		var path: Array[Vector3] = []
		for i in 30:
			await _ticks(1)
			path.append(target.global_position)
		results.append({"seen": seen.map(func(e): return [e[0], e[1] - pressed_at] + e.slice(2)), "path": path, "health": target.get_health()})
		attacker.free()
		target.free()
	var first: Dictionary = results[0]
	var second: Dictionary = results[1]
	_check(first["seen"].size() == 2 and first["seen"][0][0] == "landed" and first["seen"][1][0] == "received" and first["seen"][0][1] == first["seen"][1][1], "a hit lands and is taken in the same tick, hit_landed first (%s)" % str(first["seen"]))
	_check(first["seen"][1][2] == false, "the target takes it after simulate, not during it")
	_check(first["seen"] == second["seen"] and first["health"] == second["health"], "the same tick and damage whether the target simulates before or after its attacker (%s)" % str(second["seen"]))
	_check(first["path"] == second["path"], "and the same knockback, tick for tick")


func _test_melee_hits() -> void:
	var attacker := _make_pawn(Vector3(0, 0.1, 40))
	attacker.team = 1
	var near := _make_pawn(Vector3(0, 0.1, 38.6)) # 1.4 m in front (the attacker faces -Z)
	var far := _make_pawn(Vector3(1.5, 0.1, 37.2)) # about 3.2 m away
	var friend := _make_pawn(Vector3(-0.5, 0.1, 38.8))
	friend.team = 1
	await _ticks(15)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var landed := []
	melee.hit_landed.connect(func(hit): landed.append(hit))
	var received := []
	near.hit_received.connect(func(hit): received.append(hit))
	var ai := _ai(attacker)
	ai.look_at_point(Vector3(0, 1, 30))
	await _ticks(2)
	ai.press(&"primary")
	await _ticks(6) # the swing starts on the next tick, and winds up for 8
	_check(landed.is_empty(), "nothing is hit during the wind-up")
	for i in 10:
		await get_tree().physics_frame
		if not landed.is_empty():
			break
	await _ticks(2) # the knockback's first ticks
	var pushed := near.velocity.z
	await _ticks(6) # past the 4 hit ticks
	_check(landed.size() == 1 and landed[0].target == near, "during the hit ticks, the pawn in range is hit once, though it's in the sphere for 4 ticks")
	_check(received.size() == 1 and received[0].attacker == attacker, "its receive_hit got the HitInfo, and hit_received went out")
	_check(pushed < -3.0, "it's knocked back, away from the attacker, by its own Knockback (%.1f m/s)" % pushed)
	_check(not landed.any(func(hit): return hit.target == far), "a pawn beyond attack_range isn't hit")
	_check(not landed.any(func(hit): return hit.target == friend), "nor one on its own team")
	var listed: Array[String] = (attacker.get_node("TickState") as TickStateComponent).state_properties
	_check(listed.has("AbilityManager/MeleeAttack:ticks_left") and listed.has("AbilityManager/Knockback:push_velocity") and listed.has("AbilityManager/Dash:dash_direction"), "the swing's timer, the push and the dash direction all roll back")
	attacker.free()
	near.free()
	far.free()
	friend.free()


func _test_server_only_and_replays() -> void:
	var attacker := _make_pawn(Vector3(0, 0.1, 60))
	attacker.team = 1
	var target := _make_pawn(Vector3(0, 0.1, 58.6))
	await _ticks(15)
	var melee: MeleeAttackAbility = attacker.ability_manager.get_node("MeleeAttack")
	var landed := []
	melee.hit_landed.connect(func(hit): landed.append(hit))
	var ai := _ai(attacker)
	ai.look_at_point(Vector3(0, 1, 50))
	await _ticks(2)
	# As a client: the swing plays, but hits are the server's to decide.
	var real_entity: NetworkEntity = attacker._entity
	var client_entity := NetworkEntity.new()
	client_entity.role = NetworkEntity.Role.LOCAL_PREDICTED
	attacker._entity = client_entity
	ai.press(&"primary")
	await _ticks(20)
	_check(landed.is_empty() and not attacker.is_authority(), "on a client the swing hits nothing")
	attacker._entity = real_entity
	client_entity.free()
	await _ticks(30)
	ai.press(&"primary")
	await _ticks(20)
	_check(landed.size() == 1, "as the authority it hits")
	var went_back: bool = TickDriver.rollback(TickDriver.tick - 12)
	_check(went_back and landed.size() == 1, "a rollback replaying the hit ticks doesn't hit again")
	attacker.free()
	target.free()


func _test_view_ticks_behind() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	var negative := pawn.sanitize_network_input({"view_ticks_behind": -4.0})
	var nan := pawn.sanitize_network_input({"view_ticks_behind": NAN})
	var wrong := pawn.sanitize_network_input({"view_ticks_behind": "far"})
	var fine := pawn.sanitize_network_input({"view_ticks_behind": 6.5})
	_check(negative["view_ticks_behind"] == 0.0 and nan["view_ticks_behind"] == 0.0 and wrong["view_ticks_behind"] == 0.0, "view_ticks_behind from a client: negative, NaN or the wrong type become 0")
	_check(fine["view_ticks_behind"] == 6.5, "a sensible value passes through (LagCompensation limits how far back it goes)")
	var tick_state: TickStateComponent = pawn.get_node("TickState")
	_check(tick_state.input_properties.has("view_ticks_behind @float"), "it's in the pawn's input list, so a client's swing carries it")
	pawn.free()


func _test_ai_attacks() -> void:
	var goblin: Pawn = load(PAWN_SCENE).instantiate()
	goblin.team = 1
	goblin.position = Vector3(0, 0.1, 80)
	var behaviours := AIBehaviourManager.new()
	behaviours.name = "AIBehaviourManager"
	for pair in [["Chase", AIChaseBehaviour], ["Attack", AIAttackBehaviour]]:
		var behaviour: AIBehaviourBase = pair[1].new()
		behaviour.name = pair[0]
		behaviours.add_child(behaviour)
	goblin.add_child(behaviours)
	add_child(goblin)
	var intruder := _make_pawn(Vector3(0, 0.1, 74))
	await _ticks(5)
	var melee: MeleeAttackAbility = goblin.ability_manager.get_node("MeleeAttack")
	var landed := []
	melee.hit_landed.connect(func(hit): landed.append(hit))
	# GDScript note: a lambda gets a copy of a local number, so it records into an array, which it shares.
	var attack_started := []
	goblin.ai_behaviour_manager.behaviour_changed.connect(func(_old, new, _reason):
		if new and new.name == &"Attack":
			attack_started.append(TickDriver.tick))
	for i in 240:
		await get_tree().physics_frame
		if not landed.is_empty():
			break
	_check(goblin.ai_context.current_state_name() == &"Combat", "the goblin sees the intruder and goes into Combat")
	_check(not attack_started.is_empty(), "it chases, then switches to Attack once close enough")
	var gap := Vector2(goblin.global_position.x - intruder.global_position.x, goblin.global_position.z - intruder.global_position.z).length()
	_check(not landed.is_empty() and landed[0].target == intruder, "the swing lands (from %.2f m, inside attack_range %.1f)" % [gap, melee.attack_range])
	goblin.free()
	intruder.free()


# --- Helpers ---


func _make_pawn(at: Vector3, extra_abilities: Array = []) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	if not extra_abilities.is_empty():
		var manager: AbilityManager = load("res://assets/scenes/pawn/parts/AbilityManager.tscn").instantiate()
		for ability in extra_abilities:
			manager.add_child(ability)
		pawn.add_child(manager)
	add_child(pawn)
	return pawn


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


## Claude 2026-11-10: waits until the condition is true, or max_ticks physics frames.
func _until(condition: Callable, max_ticks: int) -> void:
	for i in max_ticks:
		if condition.call():
			return
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
