## Written by Claude (claude-opus-5-5), 2026-11-10: headless check that everything a pawn changes while it plays rolls back, the owner's
## request. The commonest desync is a new variable that changes during play but was never added to the rolled-back list
## (get_rollback_properties() on an ability, state_properties on the pawn): a correction rewinds everything else and leaves it
## behind. This finds them when they're written instead of as a mystery desync later.
##
## How: two pawns walk, sprint, jump, dash, swing and hit each other for a few seconds, and every script variable on the pawn and its
## ability and stat parts is compared tick by tick. One that changes and isn't in the pawn's TickStateComponent lists fails, unless
## it's in NOT_ROLLED_BACK below with the reason it doesn't need to. AI parts aren't checked: the AI runs on the server only, which
## never rolls back.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/pawn/tests/rollback_coverage_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]

## Variables that change during play on purpose without rolling back, as "Script name:variable", each with why. A new variable that
## changes during play belongs in its rolled-back list, unless it's one of these kinds.
const NOT_ROLLED_BACK := {
	# Worked out from the abilities' timers, which roll back: a timer starting or stopping, including a rollback loading it through
	# its setter, marks these to be worked out again before they're next used.
	"AbilityManager:_locked_mask": "worked out from the timers",
	"AbilityManager:_locks_dirty": "worked out from the timers",
	"AbilityManager:_timed": "worked out from the timers",
	"AbilityManager:_timers_dirty": "worked out from the timers",
	# For drawing: the body's place and facing at the last two ticks, so Visual moves smoothly between them. Never read by the
	# simulation, except that a stale one only stops a pawn resting for a tick (Pawn._can_rest), which is safe.
	"Pawn:_current_position": "drawing",
	"Pawn:_current_yaw": "drawing",
	"Pawn:_previous_position": "drawing",
	"Pawn:_previous_yaw": "drawing",
	# Worked out fresh every tick from rolled-back state (Pawn._can_rest: "nothing remembered"); kept for readouts.
	"Pawn:is_resting": "worked out each tick",
	# Walk's and Sprint's copies of their stats, read again whenever the StatManager's version changes (pawn spec 15.2). Sprint fills
	# them the first time it runs; Walk already has by the time play starts here, but the same holds for it.
	"SprintAbility:_acceleration": "a cache of stats",
	"SprintAbility:_air_control": "a cache of stats",
	"SprintAbility:_deceleration": "a cache of stats",
	"SprintAbility:_speed": "a cache of stats",
	"SprintAbility:_stats_speed_stat": "a cache of stats",
	"SprintAbility:_stats_version": "a cache of stats",
	"SprintAbility:_turn_rate": "a cache of stats",
	"WalkAbility:_acceleration": "a cache of stats",
	"WalkAbility:_air_control": "a cache of stats",
	"WalkAbility:_deceleration": "a cache of stats",
	"WalkAbility:_speed": "a cache of stats",
	"WalkAbility:_stats_speed_stat": "a cache of stats",
	"WalkAbility:_stats_version": "a cache of stats",
	"WalkAbility:_turn_rate": "a cache of stats",
	# Claude 2026-11-10 (pawn spec 8.11): the EffectManager's active list rolls back as active_effects, which is a window onto
	# _entries; the rest is what its held parts add up to, worked out from that list whenever it changes, rollback loads included.
	"EffectManager:_entries": "the storage behind active_effects, which rolls back",
	"EffectManager:_dirty": "worked out from active_effects",
	"EffectManager:_stat_changes": "worked out from active_effects",
	"EffectManager:_touched_stats": "worked out from active_effects",
	"EffectManager:_ability_bonuses": "worked out from active_effects",
	"EffectManager:_resistance_bits": "worked out from active_effects",
	# A stat's value, while a held StatModifierPart changes it: base_value with the parts' changes, worked out the same way.
	"Stat:value": "worked out from active_effects",
	# Goes up whenever a stat's value changes, so abilities that keep stat values read them again (pawn spec 15.2). A rollback that
	# puts a value back changes it again, so it never needs to go back itself.
	"StatManager:version": "a change counter for caches",
	# Who this swing has already hit, so each pawn is hit once. Hits are decided on the authority only and never in a replay, and the
	# server never rolls back, so this is never needed on a machine that does. Hidden before 2026-11-10 by the shared keys.
	"MeleeAttackAbility:_hit_this_swing": "on the server only, which never rolls back",
}

var _failures := 0


func _ready() -> void:
	print("--- Rollback coverage self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	var a := _pawn(Vector3(0, 0.1, 0), 1)
	var b := _pawn(Vector3(0, 0.1, -1.4), 2)
	# Claude 2026-11-10 (pawn spec 8.11): a's swing also slows what it hits, and boosts a's own dash for a moment, so over-time
	# effects, a changed stat and a changed ability number are part of the fight.
	_add_test_effects(a)
	var applied_to_a: Array[StringName] = []
	a.effect_manager.effect_applied.connect(func(effect: Effect, _application: EffectApplication) -> void: applied_to_a.append(effect.effect_name))
	await _ticks(20) # parts settle: one-off setup and caches filled on the first ticks aren't play
	var watched: Array[Node] = []
	for pawn in [a, b]:
		watched.append_array(_watched_nodes(pawn))
	var registered := {}
	for pawn in [a, b]:
		_add_registered(pawn, registered)
	var before := _snapshot(watched)
	var changed := {} # "Script:variable" -> true
	var hands_a := _ai(a)
	var hands_b := _ai(b)
	for step in 360:
		match step:
			0: hands_a.look_at_point(b.global_position + Vector3.UP)
			10: hands_a.press(&"primary")
			40: hands_b.move_in_direction(Vector3(1, 0, 0))
			50: hands_b.hold(&"sprint")
			80: hands_b.press(&"jump")
			120: hands_b.press(&"dash")
			150:
				hands_b.hold(&"sprint", false)
				hands_b.stop()
			160: hands_b.look_at_point(a.global_position + Vector3.UP)
			170: hands_b.press(&"primary")
			200: hands_a.press(&"dash")
			260: hands_a.press(&"primary")
		await get_tree().physics_frame
		var now := _snapshot(watched)
		for key in now:
			if before.has(key) and not _same(before[key], now[key]):
				changed[key.split("|")[2]] = key.split("|")[1] # Claude 2026-11-10: the key has the pawn first now
		before = now
	var unlisted: Array[String] = []
	var excused: Array[String] = []
	for key in changed:
		var node_path: String = changed[key]
		var variable := String(key).split(":")[1]
		if registered.has("%s:%s" % [node_path, variable]):
			continue
		if NOT_ROLLED_BACK.has(key):
			excused.append(key)
		else:
			unlisted.append("%s (on %s)" % [key, node_path])
	unlisted.sort()
	print("  changed during play: %d variables, %d excused (not rolled back on purpose)" % [changed.size(), excused.size()])
	for line in unlisted:
		print("    not rolled back: " + line)
	_check(unlisted.is_empty(), "every variable that changes during play rolls back or is listed in NOT_ROLLED_BACK with why (%d not)" % unlisted.size())
	var stale: Array[String] = []
	for key in NOT_ROLLED_BACK:
		if not changed.has(key):
			stale.append(key)
	print("    (listed but not seen changing this run: %s)" % ", ".join(stale) if not stale.is_empty() else "    (every listed variable was seen changing)")
	_check(changed.size() > 10, "the run exercised the pawns: %d variables changed" % changed.size())
	_check(applied_to_a.has(&"coverage dash boost"), "a's swing put its on-hit boost on a (%s)" % [applied_to_a])
	_check(changed.has("EffectManager:_entries") and changed.has("Stat:value"), "and over-time effects were on them, changing a stat (Claude 2026-11-10)")
	a.free()
	b.free()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


# The pawn, and its parts that simulate during a rollback: abilities and stats. Not AI, not visuals. Claude 2026-11-10: and effects.
func _watched_nodes(pawn: Pawn) -> Array[Node]:
	var out: Array[Node] = [pawn]
	if pawn.effect_manager:
		out.append(pawn.effect_manager)
	for part in [pawn.ability_manager, pawn.stat_manager]:
		if part == null:
			continue
		out.append(part)
		for child in part.get_children():
			if child.get_script() != null:
				out.append(child)
	return out


# Every "path:property" the pawn's TickStateComponent rolls back or takes as input, the path relative to the pawn ("" for the pawn).
func _add_registered(pawn: Pawn, out: Dictionary) -> void:
	for child in pawn.get_children():
		if child is TickStateComponent:
			for entry in child.state_properties + child.input_properties:
				var text := String(entry).split(" ")[0] # drops an encoding such as " @angle_u16"
				var parts := text.split(":")
				var path := parts[0] if parts.size() == 2 else ""
				var property := parts[parts.size() - 1]
				out["%s:%s" % [_label(pawn, pawn.get_node_or_null(path) if path != "" else pawn), property]] = true


# "path|Script:variable" -> value, for every script variable on these nodes. Objects are compared by identity, the rest by value.
# Claude 2026-11-10: "pawn|path|Script:variable": with the pawn's instance id first. Both pawns' parts shared one key before, so the
# second pawn's value hid any change on the first.
func _snapshot(nodes: Array[Node]) -> Dictionary:
	var out := {}
	for node in nodes:
		if not is_instance_valid(node):
			continue
		var script: Script = node.get_script()
		var script_name: String = script.get_global_name() if script.get_global_name() != &"" else script.resource_path.get_file().get_basename()
		var path := _label(_pawn_of(node), node)
		for property in node.get_property_list():
			if property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
				continue
			var value: Variant = node.get(property["name"])
			if value is Object:
				value = value.get_instance_id() if is_instance_valid(value) else 0
			elif value is Array or value is Dictionary:
				value = value.duplicate(true)
			elif typeof(value) >= TYPE_PACKED_BYTE_ARRAY and typeof(value) < TYPE_MAX:
				value = value.duplicate() # Claude 2026-11-10: packed arrays are shared too, so without a copy a change never shows
			out["%d|%s|%s:%s" % [_pawn_of(node).get_instance_id(), path, script_name, property["name"]]] = value
	return out


# The pawn a watched node belongs to: itself, or the nearest Pawn above it.
func _pawn_of(node: Node) -> Node:
	var at := node
	while at and not at is Pawn:
		at = at.get_parent()
	return at


# The node's path from its pawn, without the pawn's own name, so both pawns' parts share one key.
func _label(pawn: Node, node: Node) -> String:
	return "" if node == pawn or node == null else String(pawn.get_path_to(node))


# Claude 2026-11-10: on a's swing, an on-hit slow for the target and an on-hit boost to its own dash. Added before the pawn's first
# tick, and collected again by the manager, as a scene's EffectApplier children would be.
func _add_test_effects(pawn: Pawn) -> void:
	var melee: AbilityBase = pawn.ability_manager.get_node("MeleeAttack")
	var slow := Effect.new()
	slow.effect_name = &"coverage slow"
	slow.duration_seconds = 1.0
	var slower := StatModifierPart.new()
	slower.stat = &"MoveSpeed"
	slower.multiply = 0.5
	slow.parts = [slower]
	var boost := Effect.new()
	boost.effect_name = &"coverage dash boost"
	boost.is_harmful = false
	boost.duration_seconds = 1.0
	var stronger := AbilityPriorityPart.new()
	stronger.ability_tag = Tags.MOVEMENT_DASH
	stronger.number = AbilityPriorityPart.Number.INTERRUPT_PRIORITY
	stronger.amount = 5
	boost.parts = [stronger]
	var on_target := EffectApplier.new()
	on_target.effects = [slow]
	var on_self := EffectApplier.new()
	on_self.applies_to = EffectApplier.AppliesTo.SELF
	on_self.effects = [boost]
	melee.add_child(on_target)
	melee.add_child(on_self)
	pawn.ability_manager._collect_effects(melee)


func _same(x: Variant, y: Variant) -> bool:
	return typeof(x) == typeof(y) and x == y


func _pawn(at: Vector3, team: int) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.team = team
	pawn.position = at
	add_child(pawn)
	return pawn


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
