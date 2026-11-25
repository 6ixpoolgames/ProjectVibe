## Written by Claude (claude-opus-5-5), 2026-11-25: headless self-test for AI behaviour definitions (pawn spec 16.3, 16.10 step 6c):
## each kind's defaults, definition files and variants, settings written on a node, a definition of another kind, the lock on shared
## settings while playing, make_definition_unique and use_definition, the sample scenes' definitions, and the registry's ids.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/ai/tests/ai_behaviour_definition_selftest.tscn"
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const FACTION_GOBLIN := "res://assets/scenes/samples/faction_goblin.tscn"
const GOBLIN_CHASE := "res://assets/scripts/resources/ai_behaviours/goblin_chase.tres"
const HEAVY_ATTACK := "res://assets/scripts/resources/ai_behaviours/heavy_attack.tres"
const SHOOT := "res://assets/scripts/resources/ai_behaviours/shoot.tres"
const NEVER := 100000000 # a decision interval so long the pawn never decides on its own


func _ready() -> void:
	print("--- AI behaviour definition self-test ---")
	_test_kind_defaults()
	_test_definition_files()
	_test_written_on_the_node()
	_test_another_kind()
	await _test_while_playing()
	await _test_sample_scenes()
	_test_registry()
	_finish()


func _test_kind_defaults() -> void:
	var one := AIChaseBehaviour.new()
	var two := AIChaseBehaviour.new()
	_check(one.settings is AIChaseDefinition and one.settings.max_score == 0.8 and one.settings.needs_target, "with no definition it runs with its kind's defaults (an AIChaseDefinition: 0.8, needs a target)")
	_check(two.settings == one.settings and one.definition_note() == "" and not one.has_own_settings(), "and every node of the kind shares them")
	_check(one.max_score == 0.8 and one.repath_ticks == 20 and one.tags == [Tags.AI.STANCE_MELEE], "the node reads each setting by name from them")
	var wander := AIWanderBehaviour.new()
	var attack := AIAttackBehaviour.new()
	_check(wander.settings.max_score == 0.1 and attack.settings.presses_action == &"primary", "each kind has its own defaults (Wander 0.1; Attack presses primary)")
	var look := AILookTowardBehaviour.new()
	_check(look.settings.modifier_on_start != null and look.settings.modifier_on_start.add == -0.3, "a kind's default modifier_on_start comes with it (Look Toward steps aside)")
	for node in [one, two, wander, attack, look]:
		node.free()


func _test_definition_files() -> void:
	var chase := AIChaseBehaviour.new()
	chase.definition = load(GOBLIN_CHASE)
	_check(chase.settings.dash_to_close and chase.settings.max_score == 0.8 and chase.settings.repath_ticks == 20, "a definition file changes what it sets (dash_to_close); the rest are the kind's defaults")
	_check(chase.definition_note() == "" and chase.definition.describe() == "Goblin Chase", "a file is the normal case: nothing for diagnostics to flag")
	var variant := AIAttackDefinition.new()
	variant.based_on = load(HEAVY_ATTACK)
	variant.min_distance = 2.0
	var attack := AIAttackBehaviour.new()
	attack.definition = variant
	_check(attack.settings.presses_action == &"secondary" and attack.settings.max_score == 0.95 and attack.settings.min_distance == 2.0, "a variant follows its base (secondary, 0.95) and keeps its own change (min_distance 2)")
	chase.free()
	attack.free()


func _test_written_on_the_node() -> void:
	var quick := AIWanderBehaviour.new()
	var other := AIWanderBehaviour.new()
	quick.max_score = 0.3
	quick.wander_radius = 4.0
	_check(quick.settings.max_score == 0.3 and quick.settings.wander_radius == 4.0 and quick.settings.min_score == 0.1, "a setting written on a node before it plays goes on top of its kind's defaults")
	_check(quick.has_own_settings() and quick.definition_note() == "own settings", "and diagnostics says it has settings of its own")
	_check(other.settings.max_score == 0.1 and not other.has_own_settings(), "another node of the kind is unchanged")
	quick.tags = [&"ai.stance.melee"]
	_check(quick.settings.tags is Array and (quick.settings.tags as Array).is_typed(), "a plain list written on the node takes the setting's typed list")
	quick.free()
	other.free()


func _test_another_kind() -> void:
	var chase := AIChaseBehaviour.new()
	chase.definition = AIAttackDefinition.new()
	_check(chase.settings is AIChaseDefinition and chase.settings.max_score == 0.8 and chase.definition_note() == "fell back", "a definition of another kind: it runs with its kind's defaults, and diagnostics says so")
	chase.free()


func _test_while_playing() -> void:
	var first := _pawn_with_attack(0.0)
	var second := _pawn_with_attack(50.0)
	add_child(first)
	add_child(second)
	await get_tree().physics_frame
	var attack: AIAttackBehaviour = first.ai.behaviour_manager.get_node("Attack")
	var other: AIAttackBehaviour = second.ai.behaviour_manager.get_node("Attack")
	attack.approach_margin = 1.0 # an error: the definition is shared
	_check(attack.settings.approach_margin == 0.3 and not attack.has_own_settings(), "while playing, a shared setting can't be written: every pawn using it would change")
	attack.make_definition_unique()
	attack.approach_margin = 1.0
	_check(attack.settings.approach_margin == 1.0 and other.settings.approach_margin == 0.3 and attack.definition_note() == "own settings", "after make_definition_unique it can, for that pawn only")
	attack.use_definition(load(SHOOT))
	var described: Dictionary = first.ai.behaviour_manager.describe()["behaviours"][0]
	_check(attack.settings.presses_action == &"ability_3" and attack.settings.approach_margin == 1.0, "use_definition swaps its definition in play; its own changes stay on top")
	_check(described["presses_action"] == "ability_3" and described["max_score"] == 0.97 and described["definition"] == "Shoot", "and the brain C++ gets has the new settings and names the definition")
	first.queue_free()
	second.queue_free()
	await get_tree().physics_frame


func _test_sample_scenes() -> void:
	var goblin: Pawn = load(FACTION_GOBLIN).instantiate()
	goblin.position = Vector3(0, 1000, 0)
	add_child(goblin)
	await get_tree().physics_frame
	var behaviours := goblin.ai.behaviour_manager
	var heavy: AIAttackBehaviour = behaviours.get_node("HeavyAttack")
	var shoot: AIAttackBehaviour = behaviours.get_node("Shoot")
	var chase: AIChaseBehaviour = behaviours.get_node("Chase")
	_check(heavy.settings.presses_action == &"secondary" and heavy.settings.max_score == 0.95 and heavy.definition_note() == "", "the faction goblin's Heavy Attack runs with heavy_attack.tres")
	_check(shoot.settings.presses_action == &"ability_3" and shoot.settings.min_distance == 4.0 and shoot.definition_note() == "", "its Shoot with shoot.tres")
	_check(chase.settings.dash_to_close and chase.definition_note() == "", "its Chase with goblin_chase.tres (inherited from the arena goblin)")
	goblin.queue_free()
	await get_tree().physics_frame


func _test_registry() -> void:
	DefinitionRegistry.scan()
	var chase: Definition = load(GOBLIN_CHASE)
	_check(DefinitionRegistry.index_of(chase) >= 0 and DefinitionRegistry.find(DefinitionRegistry.index_of(chase)) == chase, "behaviour definition files get an id from the registry, as ability ones do")


func _pawn_with_attack(x: float) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = Vector3(x, 1000, 0)
	var manager := AIBehaviourManager.new()
	manager.name = "AIBehaviourManager"
	var attack := AIAttackBehaviour.new()
	attack.name = "Attack"
	manager.add_child(attack)
	AITestPawns.ai_of(pawn).add_child(manager)
	pawn.ready.connect(func() -> void: pawn.ai.decision_interval_ticks = NEVER)
	return pawn
