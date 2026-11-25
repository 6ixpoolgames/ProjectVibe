## Written by Claude (claude-opus-5-5), 2026-11-22: headless self-test for owned tags and tag queries (tag spec 3 and 4, step 2):
## counting, sources replacing their tags, parents answering, the changed signal, queries (all of, any of, none of, unknown tags,
## edits), and on a real pawn: a timed ability's run, held effects, death, the AI's state, and loose tags through a rollback.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   bash tools/run_tests.sh owned_tags
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]


func _ready() -> void:
	print("--- Owned tags self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # these checks count ticks at 60
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	_test_counts_and_sources()
	_test_queries()
	await _test_ability_run()
	await _test_effects()
	await _test_death()
	await _test_ai_state()
	await _test_loose_rollback()
	_finish()


func _test_counts_and_sources() -> void:
	var owned := OwnedTags.new() # on its own, outside a pawn: nothing to push to
	var seen: Array = []
	owned.changed.connect(func(tag, is_owned): seen.append([tag, is_owned]))
	owned.add(Tags.STATUS.DEAD)
	owned.add(Tags.STATUS.DEAD)
	_check(owned.has(Tags.STATUS.DEAD) and owned.count_of(Tags.STATUS.DEAD) == 2, "a loose tag added twice is owned twice")
	_check(owned.has(Tags.STATUS.ALL), "owning a tag owns its parents")
	owned.remove(Tags.STATUS.DEAD)
	_check(owned.has(Tags.STATUS.DEAD), "one removal of two leaves it owned")
	owned.remove(Tags.STATUS.DEAD, 5)
	_check(not owned.has(Tags.STATUS.DEAD) and not owned.has(Tags.STATUS.ALL) and owned.count_of(Tags.STATUS.DEAD) == 0, "removing more than was added takes it to 0, parents too")
	_check_equal(seen, [[Tags.STATUS.DEAD, true], [Tags.STATUS.DEAD, false]], "changed fires only when a tag starts or stops being owned")

	owned.set_source(&"a", [Tags.ABILITY.COMBAT_MELEE, Tags.EFFECT.DEBUFF_SLOW])
	owned.set_source(&"b", [Tags.ABILITY.COMBAT_MELEE])
	_check(owned.count_of(Tags.ABILITY.COMBAT_MELEE) == 2 and owned.has(Tags.ABILITY.COMBAT), "two sources adding one tag count twice; parents answer")
	_check(owned.has(Tags.EFFECT.DEBUFF) and not owned.has(Tags.EFFECT.BUFF), "tags of several categories, each in its own word")
	owned.set_source(&"a", [Tags.ABILITY.MOVEMENT_DASH])
	_check(owned.count_of(Tags.ABILITY.COMBAT_MELEE) == 1 and not owned.has(Tags.EFFECT.DEBUFF_SLOW) and owned.has(Tags.ABILITY.MOVEMENT_DASH), "a source's new list replaces its last")
	owned.clear_source(&"b")
	owned.clear_source(&"a")
	_check(owned.get_owned().is_empty() and not owned.has(Tags.ABILITY.ALL), "clearing every source owns nothing")
	owned.add(Tags.STATUS.DEAD)
	owned.remove(Tags.ABILITY.COMBAT_MELEE)
	owned.set_source(&"a", [Tags.ABILITY.COMBAT_MELEE])
	owned.remove(Tags.ABILITY.COMBAT_MELEE)
	_check(owned.has(Tags.ABILITY.COMBAT_MELEE), "remove() never takes a source's tag")

	var count := TagRegistry.get_tag_count()
	_check(not owned.has(&"status.never_declared") and TagRegistry.get_tag_count() == count, "asking about an undeclared tag says no and adds nothing")
	_check(owned.loose_count_of(Tags.STATUS.DEAD) == 1 and owned.loose_counts == {Tags.STATUS.DEAD: 1}, "loose counts are kept apart from sources")
	owned.loose_counts = {}
	_check(not owned.has(Tags.STATUS.DEAD) and owned.has(Tags.ABILITY.COMBAT_MELEE), "loading the loose tags (a rollback) takes away only loose ones")
	owned.loose_counts = {Tags.STATUS.DEAD: 3}
	_check(owned.count_of(Tags.STATUS.DEAD) == 3, "loading a count puts it back as that many")
	owned.free()


func _test_queries() -> void:
	var owned := OwnedTags.new()
	owned.set_source(&"s", [Tags.ABILITY.COMBAT_MELEE, Tags.AI.STATE_COMBAT])
	_check(TagQuery.new().matches(owned) and TagQuery.new().matches(null), "an empty query passes, even with no owner")
	_check(TagQuery.make([Tags.ABILITY.COMBAT, Tags.AI.STATE_COMBAT]).matches(owned), "all_of: every tag owned, a parent covering the tag under it")
	_check(not TagQuery.make([Tags.ABILITY.COMBAT, Tags.STATUS.DEAD]).matches(owned), "all_of fails if one is missing")
	_check(TagQuery.make([], [Tags.STATUS.DEAD, Tags.ABILITY.COMBAT_MELEE]).matches(owned), "any_of: one owned is enough")
	_check(not TagQuery.make([], [Tags.STATUS.DEAD, Tags.ABILITY.COMBAT_RANGED]).matches(owned), "any_of fails if none is owned")
	_check(not TagQuery.make([], [], [Tags.AI.STATE]).matches(owned), "none_of: a parent catches the tag under it")
	_check(TagQuery.make([], [], [Tags.STATUS.DEAD]).matches(owned), "none_of passes if none is owned")
	_check(not TagQuery.make([Tags.ABILITY.COMBAT], [Tags.STATUS.DEAD], [Tags.AI.STATE_IDLE]).matches(owned), "all three lists must pass")
	_check(not TagQuery.make([Tags.ABILITY.COMBAT], [], [], ).matches(null), "a null owner owns nothing")

	var count := TagRegistry.get_tag_count()
	_check(not TagQuery.make([&"status.never_declared"]).matches(owned), "an undeclared tag in all_of can't be owned, so the query fails")
	_check(TagQuery.make([], [], [&"status.never_declared"]).matches(owned), "an undeclared tag in none_of counts for nothing")
	_check(TagRegistry.get_tag_count() == count, "queries never add tags")

	var query := TagQuery.make([Tags.ABILITY.COMBAT_MELEE])
	_check(query.matches(owned), "(a query that passes)")
	query.all_of = [Tags.ABILITY.COMBAT_RANGED] as Array[StringName]
	_check(not query.matches(owned), "assigning a new list is noticed")
	owned.set_source(&"s", [Tags.ABILITY.COMBAT_RANGED])
	_check(query.matches(owned) and owned.matches(query) and owned.matches(null), "owned tags changing are seen at once; OwnedTags.matches agrees")
	_check(query.describe() == "all of [&\"ability.combat.ranged\"]" and TagQuery.new().describe() == "anything", "describe() names the lists")

	# After the registry is renumbered (a reset in a test or tool), queries and owned tags work their bits out again.
	TagRegistry.reset()
	_check(query.matches(owned) and owned.has(Tags.ABILITY.COMBAT), "bits are worked out again after a registry reset")
	owned.free()


func _test_ability_run() -> void:
	var p := _pawn(Vector3(0, 0.1, 0))
	await _ticks(3)
	_check(p.owned_tags != null and p.owned_tags.pawn == p, "a pawn gets its OwnedTags part from the defaults")
	var dash: AbilityBase = p.get_node("AbilityManager/Dash")
	_check(not p.owned_tags.has(Tags.ABILITY.MOVEMENT_DASH), "(not dashing yet)")
	p.ability_manager.start_ability(dash)
	_check(dash.is_running_timed() and p.owned_tags.has(Tags.ABILITY.MOVEMENT_DASH) and p.owned_tags.has(Tags.ABILITY.MOVEMENT), "a running timed ability owns its category, and the parents")
	for extra in dash.extra_categories:
		_check(p.owned_tags.has(extra), "and its extra category %s" % extra)
	var saved := dash.ends_at
	await _ticks(60)
	_check(not dash.is_running_timed() and not p.owned_tags.has(Tags.ABILITY.MOVEMENT_DASH), "the tags go when the run ends")
	dash.ends_at = saved # what a rollback loading a tick inside the run does
	_check(p.owned_tags.has(Tags.ABILITY.MOVEMENT_DASH), "loading a running ends_at (a rollback, a snapshot) owns the tags again")
	dash.ends_at = -1
	_check(not p.owned_tags.has(Tags.ABILITY.MOVEMENT_DASH), "and loading a stopped one takes them away")
	p.free()


func _test_effects() -> void:
	var p := _pawn(Vector3(5, 0.1, 0))
	await _ticks(3)
	var before := p.status_manager.active_effects.duplicate()
	var slow := Effect.new()
	slow.effect_name = &"owned tags test slow"
	slow.duration_ticks = 30
	slow.tags = [Tags.EFFECT.DEBUFF_SLOW] as Array[StringName]
	p.status_manager.apply_effect(slow, null)
	_check(p.owned_tags.has(Tags.EFFECT.DEBUFF_SLOW) and p.owned_tags.has(Tags.EFFECT.DEBUFF), "a held effect's tags are owned while it's on the pawn")
	var during := p.status_manager.active_effects.duplicate()
	p.status_manager.active_effects = before
	_check(not p.owned_tags.has(Tags.EFFECT.DEBUFF_SLOW), "loading the list from before it (a rollback) takes them away at once")
	p.status_manager.active_effects = during
	_check(p.owned_tags.has(Tags.EFFECT.DEBUFF_SLOW), "loading it back puts them back")
	await _ticks(40)
	_check(not p.status_manager.has_effect(slow) and not p.owned_tags.has(Tags.EFFECT.DEBUFF), "the tags go when it runs out")
	p.free()


func _test_death() -> void:
	var p := _pawn(Vector3(10, 0.1, 0))
	await _ticks(3)
	p.status_manager.apply_effect(Effect.make_damage(100000.0), null)
	await _ticks(2)
	_check(p.is_dead() and p.owned_tags.has(Tags.STATUS.DEAD) and p.owned_tags.has(Tags.ABILITY.DEATH), "a dead pawn owns status.dead, and ability.death while Death runs")
	_check(TagQuery.make([], [], [Tags.STATUS.DEAD]).matches(p.owned_tags) == false, "a 'not when dead' query fails for it")
	p.ability_manager.revive()
	await _ticks(3)
	_check(not p.is_dead() and not p.owned_tags.has(Tags.STATUS.ALL) and not p.owned_tags.has(Tags.ABILITY.DEATH), "revived: neither is owned")
	p.free()


func _test_ai_state() -> void:
	var p: Pawn = load(PAWN_SCENE).instantiate()
	p.position = Vector3(15, 0.1, 0)
	add_child(p)
	p.ai.decision_interval_ticks = 1 # decide every tick, so the first state is picked at once
	await _ticks(10)
	var states := p.ai.state_manager
	var current := states.get_current_state()
	_check(current != null and p.owned_tags.has(current.get_tag()) and p.owned_tags.has(Tags.AI.STATE), "the pawn owns its AI state's tag (%s)" % (current.get_tag() if current else &"none"))
	_check(TagRegistry.read_declared_tags([Tags.AI.ALL]).has(current.get_tag()) if current else false, "the default states' tags are declared")
	states.force_state(&"Combat", 120, 50, "owned tags test")
	await _ticks(3)
	_check(p.owned_tags.has(Tags.AI.STATE_COMBAT) and p.owned_tags.get_owned().filter(func(t): return String(t).begins_with("ai.state.")).size() == 1, "a new state replaces the last state's tag")
	p.free()


func _test_loose_rollback() -> void:
	var p := _pawn(Vector3(20, 0.1, 0))
	await _ticks(3)
	var tick_state: TickStateComponent = p.get_node("TickState")
	_check(Array(tick_state.state_properties).has("OwnedTags:loose_counts pushed"), "loose tags are in the pawn's rolled-back state")
	var without := TickDriver.tick - 1
	p.owned_tags.add(Tags.STATUS.DEAD)
	await _ticks(3)
	var with := TickDriver.tick - 1
	await _ticks(2)
	_check(TickDriver.rollback(with) and p.owned_tags.has(Tags.STATUS.DEAD), "a rollback to a tick after the tag was added keeps it")
	_check(TickDriver.rollback(without) and not p.owned_tags.has(Tags.STATUS.DEAD), "a rollback to a tick before it was added takes it away")
	p.free()


# --- Helpers ---


func _pawn(at: Vector3) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.position = at
	add_child(pawn)
	return pawn


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
