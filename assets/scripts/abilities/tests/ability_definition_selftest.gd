## Written by Claude (claude-opus-5-5), 2026-11-21: headless self-test for ability definitions (ability spec 3, abilities step part 2):
## the kind's defaults, variants that follow their base, what a variant's file saves, falling back from a definition of another kind,
## settings written on a node, make_definition_unique and use_definition, the sample scenes' definitions, and the registry's ids.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/abilities/tests/ability_definition_selftest.tscn"
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const DEFINITIONS := "res://assets/scripts/resources/abilities/"
const SCRATCH := "user://ability_definition_selftest/"


func _ready() -> void:
	print("--- Ability definition self-test ---")
	_test_kind_defaults()
	_test_variants()
	_test_variant_file()
	_test_fallback_and_node_writes()
	await _test_while_playing()
	_test_sample_scenes()
	_test_registry()
	_finish()


func _test_kind_defaults() -> void:
	var one := MeleeAttackAbility.new()
	var two := MeleeAttackAbility.new()
	var settings := one.prepare_settings()
	_check(settings is MeleeAttackDefinition and settings.category == Tags.ABILITY.COMBAT_MELEE and settings.windup_ticks == 8, "with no definition it runs with its kind's defaults (a MeleeAttackDefinition: combat.melee, windup 8)")
	_check(two.prepare_settings() == settings and one.definition_note() == "", "and every node of the kind shares them")
	_check(one.windup_ticks == 8 and one.locks_out == [Tags.ABILITY.MOVEMENT, Tags.ABILITY.COMBAT], "the node reads each setting from them")
	var walk := WalkAbility.new()
	var sprint := SprintAbility.new()
	_check(walk.prepare_settings().interrupt_threshold == 0 and sprint.prepare_settings() is SprintDefinition, "each kind has its own defaults (Walk: threshold 0; Sprint: a SprintDefinition)")
	for node in [one, two, walk, sprint]:
		node.free()


func _test_variants() -> void:
	var base := MeleeAttackDefinition.new()
	base.cooldown_ticks = 60
	_check(base.changed_values.is_empty(), "a definition with no base keeps no list of changes: every value is its own")
	var variant := MeleeAttackDefinition.new()
	variant.based_on = base
	variant.windup_ticks = 3
	_check(variant.changed_values == PackedStringArray(["windup_ticks"]), "a variant keeps the settings it changed (%s)" % str(variant.changed_values))
	var resolved := variant.resolved()
	_check(resolved.windup_ticks == 3 and resolved.cooldown_ticks == 60 and resolved.based_on == null and resolved.resolved_from == variant, "worked out: its own windup, its base's cooldown")
	_check(variant.resolved() == resolved, "worked out once while playing")
	base.cooldown_ticks = 120
	_check(variant.value_of(&"cooldown_ticks") == 120 and variant.value_of(&"windup_ticks") == 3, "a change to the base reaches the variant; its own change stays")
	var deeper := MeleeAttackDefinition.new()
	deeper.based_on = variant
	deeper.attack_range = 3.0
	var deep := deeper.resolved()
	_check(deep.attack_range == 3.0 and deep.windup_ticks == 3 and deep.cooldown_ticks == 120, "a variant of a variant follows both")
	var sprint := SprintDefinition.new()
	sprint.based_on = WalkDefinition.new()
	_check(sprint.resolved().max_charge_ticks == 180 and sprint.resolved().trigger_action == &"", "a Sprint variant of a Walk definition: Walk's settings follow it, Sprint's own stay")
	var loop_a := MeleeAttackDefinition.new()
	var loop_b := MeleeAttackDefinition.new()
	loop_a.based_on = loop_b
	loop_b.based_on = loop_a
	print("  (an error about bases leading back to themselves is expected next)")
	_check(loop_a.value_of(&"cooldown_ticks") == 0, "bases that lead back to themselves don't hang")
	loop_a.based_on = null


func _test_variant_file() -> void:
	DirAccess.make_dir_recursive_absolute(SCRATCH)
	var base := MeleeAttackDefinition.new()
	base.cooldown_ticks = 90
	base.attack_range = 2.2
	ResourceSaver.save(base, SCRATCH + "base.tres")
	var variant := MeleeAttackDefinition.new()
	variant.based_on = load(SCRATCH + "base.tres")
	variant.windup_ticks = 4
	variant.hit_ticks = 4 # the kind's default, but changed on purpose: it must stay pinned if the base changes it
	ResourceSaver.save(variant, SCRATCH + "variant.tres")
	var text := FileAccess.get_file_as_string(SCRATCH + "variant.tres")
	_check(text.contains("windup_ticks = 4") and not text.contains("cooldown") and not text.contains("attack_range") and not text.contains("category"), "a variant's file saves only what it changed")
	var loaded: MeleeAttackDefinition = ResourceLoader.load(SCRATCH + "variant.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	var resolved := loaded.resolved()
	_check(resolved.windup_ticks == 4 and resolved.cooldown_ticks == 90 and resolved.attack_range == 2.2 and resolved.category == Tags.ABILITY.COMBAT_MELEE, "loaded: its change, its base's values, the kind's defaults")
	_check(loaded.changed_values.has("hit_ticks") and resolved.hit_ticks == 4, "a change equal to the kind's default isn't saved as a value but stays in the list, so it stays pinned")
	for file in ["base.tres", "variant.tres"]:
		DirAccess.remove_absolute(SCRATCH + file)


func _test_fallback_and_node_writes() -> void:
	var melee := MeleeAttackAbility.new()
	melee.definition = DashDefinition.new()
	print("  (a warning about a definition for another kind of ability is expected next)")
	var settings := melee.prepare_settings()
	_check(melee.definition_fell_back and settings is MeleeAttackDefinition and settings.category == Tags.ABILITY.COMBAT_MELEE and melee.definition_note() == "fell back", "a definition of another kind: it runs with its kind's defaults, and diagnostics says so")
	melee.free()
	var hero := MeleeAttackAbility.new()
	hero.definition = load(DEFINITIONS + "hero_red_swing.tres")
	hero.windup_ticks = 3 # as a script's _init(), or an old scene value, writes it before the manager sets it up
	_check(hero.windup_ticks == 3 and hero.attack_range == 2.1 and hero.cooldown_ticks == 72 and hero.definition_note() == "own settings", "a setting written on the node goes on top of its definition, for this node only")
	hero.free()
	var embedded := MeleeAttackDefinition.new()
	embedded.resource_path = "res://somewhere/goblin.tscn::MeleeAttackDefinition_x1"
	var quick := MeleeAttackAbility.new()
	quick.definition = embedded
	_check(embedded.is_embedded() and quick.definition_note() == "embedded" and embedded.describe().contains("embedded in goblin.tscn"), "a definition saved inside a scene is marked as a prototype tweak")
	quick.free()


func _test_while_playing() -> void:
	var first: Pawn = load(PAWN_SCENE).instantiate()
	var second: Pawn = load(PAWN_SCENE).instantiate()
	add_child(first)
	add_child(second)
	await get_tree().physics_frame
	var walk: WalkAbility = first.ability_manager.get_node("Walk")
	print("  (an error about writing a shared setting is expected next)")
	walk.fallback_speed = 1.0
	_check(walk.fallback_speed == 5.0 and walk.definition_note() == "", "while playing, a shared setting can't be written: every pawn using it would change")
	var sprint: SprintAbility = first.ability_manager.get_node("Sprint")
	sprint.make_definition_unique()
	sprint.max_charge_ticks = 60
	var other_sprint: SprintAbility = second.ability_manager.get_node("Sprint")
	_check(sprint.max_charge_ticks == 60 and other_sprint.max_charge_ticks == 180 and sprint.definition_note() == "own settings", "after make_definition_unique it can, for that pawn only")
	var melee: MeleeAttackAbility = first.ability_manager.get_node("MeleeAttack")
	melee.use_definition(load(DEFINITIONS + "heavy_attack.tres"))
	_check(melee.trigger_action == &"secondary" and melee.trigger_bit == InputActions.mask_of(&"secondary") and melee.windup_ticks == 22, "use_definition swaps its settings, and the manager works out its input bit again")
	first.free()
	second.free()


func _test_sample_scenes() -> void:
	var goblin: Node = load("res://assets/scenes/samples/faction_goblin.tscn").instantiate()
	var second: MeleeAttackAbility = goblin.get_node("AbilityManager/SecondSwing")
	_check(second.combo_positions == [2] and second.windup_ticks == 5 and second.priority == 20, "the faction's second swing comes from second_swing.tres")
	goblin.free()
	var hero: Node = load("res://assets/scenes/samples/hero_red.tscn").instantiate()
	var finisher: MeleeAttackAbility = hero.get_node("AbilityManager/FinisherSwing")
	_check(finisher.attack_range == 2.4 and finisher.sweep_degrees == 12.0 and finisher.windup_ticks == 10, "the red hero's finisher: its own reach (2.4), the rest from the faction's finisher")
	var kill_self: AbilityBase = hero.get_node("AbilityManager/KillSelf")
	_check(kill_self.trigger_action == &"kill_self" and kill_self.definition_note() == "", "a plain ability's settings come from a definition file too (kill_self.tres)")
	hero.free()


func _test_registry() -> void:
	DefinitionRegistry.scan()
	var table := DefinitionRegistry.table()
	var sorted := Array(table)
	sorted.sort()
	_check(DefinitionRegistry.count() >= 10 and Array(table) == sorted, "the registry finds the definition files and numbers them in UID order (%d)" % DefinitionRegistry.count())
	var hero: AbilityDefinition = load(DEFINITIONS + "hero_red_swing.tres")
	var index := DefinitionRegistry.index_of(hero)
	_check(index >= 0 and DefinitionRegistry.find(index) == hero, "a definition's index finds it again")
	_check(DefinitionRegistry.index_of(hero.resolved()) == index, "the copy an ability runs with answers for its file")
	_check(DefinitionRegistry.find_by_uid(table[index]) == hero, "its UID, the id a replay keeps, finds it too")
	_check(DefinitionRegistry.index_of(MeleeAttackDefinition.new()) == -1 and DefinitionRegistry.find(-1) == null and DefinitionRegistry.find(table.size()) == null, "one made in code has no index")
