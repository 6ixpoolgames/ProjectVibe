## Written by Claude (claude-opus-5-5), 2026-11-22: a melee stress test, the owner's request: what the shared hit system costs when a
## great many swings land at once, and what its world check adds. Not pass/fail: it prints a row every 2 s of game time.
## A grid of pawns, rows facing each other in pairs, each swinging whenever it can; Health so high nobody dies. Headless.
## Run from the project folder:
##   godot --headless --fixed-fps 60 --path . "res://assets/scripts/samples/tests/melee_stress_measure.tscn" -- --pawns=400 --seconds=10
## --los=off switches the world check off (the default hit definition's blocked_by_world), to compare. --walls puts a thin wall between
## every other pair of rows, so those swings are blocked by it (the check's rays then meet something).
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]
const SPACING := 1.4 # metres between pawns, inside a swing's reach

var _pawn_count := 400
var _seconds := 10
var _los := true
var _walls := false
var _pawns: Array[Pawn] = []
var _landed := 0


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		var parts := argument.trim_prefix("--").split("=", true, 1)
		match parts[0]:
			"pawns":
				_pawn_count = int(parts[1])
			"seconds":
				_seconds = int(parts[1])
			"los":
				_los = parts[1] != "off"
			"walls":
				_walls = true
	TickDriver.load_step_override = 1 # every pawn every tick
	AbilityBase._default_hit().blocked_by_world = _los
	_build()
	await get_tree().physics_frame
	var diagnostics := GameMode.get_module(DiagnosticsManager) as DiagnosticsManager
	if diagnostics == null:
		print("--- no DiagnosticsManager: check the project setting project_base/game_mode/modules ---")
		get_tree().quit(1)
		return
	print("--- Melee stress: %d pawns, world check %s%s ---" % [_pawns.size(), "on" if _los else "off", ", walls between every other pair of rows" if _walls else ""])
	print(" time   hits/s   tick ms   abilities ms/frame   melee.hits ms/frame (calls, us each)   world check ms/frame (calls, us each)")
	var rate := TickDriver.get_tick_rate()
	for i in _seconds * rate:
		_swing_all()
		await get_tree().physics_frame
		if i == 0 or i % (2 * rate) != 0:
			continue
		var s: Dictionary = diagnostics.get_summary(2.0)
		var abilities: Array = s.scopes.get(&"pawn.abilities", [0.0, 0.0])
		var hits: Array = s.scopes.get(&"melee.hits", [0.0, 0.0])
		var check: Array = s.scopes.get(&"hits.world_check", [0.0, 0.0])
		@warning_ignore("integer_division") # whole seconds on purpose
		print("%4ds   %6.0f   %7.2f   %18.2f   %13.2f (%6.0f, %5.1f)   %18.2f (%6.0f, %5.1f)" % [i / rate, _landed / 2.0, s.tick_ms, abilities[0],
			hits[0], hits[1], 1000.0 * hits[0] / maxf(hits[1], 1.0), check[0], check[1], 1000.0 * check[0] / maxf(check[1], 1.0)])
		_landed = 0
	get_tree().quit(0)


# A square grid: rows in pairs facing each other (team 0 faces -Z at team 1, which faces +Z), so every swing has an enemy in reach.
func _build() -> void:
	var side := ceili(sqrt(float(_pawn_count)))
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(side * SPACING + 20.0, 1.0, side * SPACING + 20.0)
	shape.shape = box
	shape.position = Vector3(side * SPACING * 0.5, -0.5, side * SPACING * 0.5)
	floor_body.add_child(shape)
	add_child(floor_body)
	for i in _pawn_count:
		@warning_ignore("integer_division") # whole rows on purpose
		var row := i / side
		var column := i % side
		var pawn: Pawn = load(PAWN_SCENE).instantiate()
		pawn.skip_default_parts = NO_AI
		pawn.team = row % 2
		pawn.position = Vector3(column * SPACING, 0.1, row * SPACING)
		pawn.rotation.y = 0.0 if row % 2 == 1 else PI # team 1 faces -Z (toward the row before), team 0 faces +Z
		add_child(pawn)
		_pawns.append(pawn)
		var health := pawn.stat_manager.get_stat(StatManager.HEALTH) if pawn.stat_manager else null
		if health:
			health.base_value = 1.0e9
			health.current = 1.0e9
		pawn.ability_manager.hit_received.connect(func(_hit: HitInfo) -> void: _landed += 1)
	if _walls:
		@warning_ignore("integer_division") # whole pairs on purpose
		for pair in side / 2:
			if pair % 2 == 1:
				var wall := StaticBody3D.new()
				var wall_shape := CollisionShape3D.new()
				var wall_box := BoxShape3D.new()
				wall_box.size = Vector3(side * SPACING, 2.0, 0.1)
				wall_shape.shape = wall_box
				wall.add_child(wall_shape)
				wall.position = Vector3(side * SPACING * 0.5, 1.0, (pair * 2 + 0.5) * SPACING)
				add_child(wall)


# Every pawn whose swing is ready swings.
func _swing_all() -> void:
	for pawn in _pawns:
		var melee := pawn.ability_manager.get_node_or_null(^"MeleeAttack") as MeleeAttackAbility
		if melee and not melee.is_running_timed() and TickDriver.tick >= melee.ready_at:
			pawn.ability_manager.start_ability(melee)
