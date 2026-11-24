## Written by Claude (claude-opus-5-5), 2026-11-04: headless self-test for TagRegistry. Checks the corner cases listed at the top of TagRegistry.gd.
## Claude 2026-11-22 (tag spec): one registry for every kind of tag, categories with a word each, redirects, deprecation, descriptions.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   bash tools/run_tests.sh tag_registry
extends Node

var _failures := 0


func _ready() -> void:
	print("--- Tag registry self-test ---")
	_test_bits_and_masks()
	_test_categories()
	_test_peers_agree()
	_test_level_search()
	_test_late_and_messy()
	_test_limit()
	_test_redirects_and_deprecation()
	_test_declarations_file()
	TagRegistry.reset() # leave the registry as the game would find it
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_bits_and_masks() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"ability.movement.walk", &"ability.combat.melee.sword", &"ability.combat.ranged"])
	# Sorted levels within the category: ability, combat, combat.melee, combat.melee.sword, combat.ranged, movement, movement.walk
	_check(TagRegistry.get_tags() == [&"ability", &"ability.combat", &"ability.combat.melee", &"ability.combat.melee.sword", &"ability.combat.ranged", &"ability.movement", &"ability.movement.walk"],
		"parent levels added and every level numbered in sorted order")
	_check(TagRegistry.bit_of(&"ability") == 0 and TagRegistry.bit_of(&"ability.movement.walk") == 6, "bit indices follow the sorted order")

	var sword := TagRegistry.mask_of(&"ability.combat.melee.sword")
	_check(sword == 0b1111, "mask holds the tag's own bit plus its parents', the category included")
	_check(TagRegistry.matches(sword, &"ability.combat"), "query 'ability.combat' matches ability.combat.melee.sword")
	_check(TagRegistry.matches(sword, &"ability.combat.melee"), "query 'ability.combat.melee' matches ability.combat.melee.sword")
	_check(TagRegistry.matches(sword, &"ability"), "the category matches every tag in it")
	_check(not TagRegistry.matches(sword, &"ability.combat.ranged"), "query 'ability.combat.ranged' doesn't match a sword")
	_check(not TagRegistry.matches(TagRegistry.mask_of(&"ability.movement.walk"), &"ability.combat"), "movement doesn't match combat")

	var locked := TagRegistry.mask_of_list([&"ability.combat.melee"])
	_check(sword & locked != 0, "locking ability.combat.melee blocks ability.combat.melee.sword")
	_check(TagRegistry.mask_of(&"ability.combat.ranged") & locked == 0, "locking ability.combat.melee leaves ability.combat.ranged free")
	_check(TagRegistry.mask_of(&"ability.combat.ranged") & TagRegistry.mask_of_list([&"ability.combat"]) != 0, "locking ability.combat blocks all of it")

	var dash := TagRegistry.full_mask_of_list([&"ability.movement.walk", &"ability.combat.melee"])
	_check(TagRegistry.matches(dash, &"ability.movement") and TagRegistry.matches(dash, &"ability.combat"), "category + extra_categories answer to both")
	_check(TagRegistry.names_of(sword, &"ability") == [&"ability", &"ability.combat", &"ability.combat.melee", &"ability.combat.melee.sword"], "names_of lists the tags in a mask")

	_check(TagRegistry.mask_of(&"") == 0 and TagRegistry.bit_of(&"") == -1, "empty tag: no bit, mask 0")
	_check(not TagRegistry.matches(sword, &""), "empty query matches nothing")
	_check(TagRegistry.mask_of(null) == 0, "null tag: mask 0, no error")


# Each category numbers its own tags in its own word, in sorted order of categories.
func _test_categories() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"nav.link.jump", &"ability.combat.melee", &"effect.damage.fire"])
	_check(TagRegistry.get_categories() == [&"ability", &"effect", &"nav"], "categories in sorted order")
	_check(TagRegistry.word_of(&"ability") == 0 and TagRegistry.word_of(&"nav") == 2 and TagRegistry.word_of(&"stealth") == -1, "each category has its own word")
	_check(TagRegistry.category_of(&"nav.link.jump") == &"nav" and TagRegistry.category_of(&"nav") == &"nav" and TagRegistry.category_of(&"") == &"", "a tag's category is its first level")
	_check(TagRegistry.bit_of(&"nav") == 0 and TagRegistry.bit_of(&"effect") == 0, "every category numbers from bit 0")
	_check(TagRegistry.names_of(TagRegistry.mask_of(&"nav.link.jump"), &"nav") == [&"nav", &"nav.link", &"nav.link.jump"], "names_of reads a mask in its own category")
	# A mask belongs to one category; a list that mixes them warns (and gives a meaningless mask).
	TagRegistry.mask_of_list([&"ability.combat.melee", &"nav.link.jump"])


func _test_peers_agree() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"ability.movement.walk", &"ability.combat.melee", &"ability.utility.heal", &"nav.point.cover"])
	var hash_a := TagRegistry.content_hash()
	var bit_a := TagRegistry.bit_of(&"ability.utility.heal")
	TagRegistry.reset(false)
	TagRegistry.declare([&"nav.point.cover", &"ability.utility.heal", &"ability.combat.melee", &"ability.movement.walk"]) # another order
	_check(TagRegistry.bit_of(&"ability.utility.heal") == bit_a, "declaration order doesn't change bits (peers agree)")
	_check(TagRegistry.content_hash() == hash_a, "content hash equal for equal declarations")
	TagRegistry.reset(false)
	TagRegistry.declare([&"ability.utility.heal", &"ability.combat.melee"])
	_check(TagRegistry.content_hash() != hash_a, "content hash differs for different declarations")


## Claude 2026-11-04: the any-level search was removed from tier 0; only root matching remains.
func _test_level_search() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"ability.combat.melee.sword", &"crafting.smithing.sword"])
	var sword := TagRegistry.mask_of(&"ability.combat.melee.sword")
	_check(not TagRegistry.matches(sword, &"sword"), "root search for 'sword' finds nothing")
	_check(not TagRegistry.has_tag(&"sword"), "...and querying an unknown tag doesn't add it")
	_check(TagRegistry.category_of(&"crafting.smithing.sword") != TagRegistry.category_of(&"ability.combat"), "crafting.smithing.sword is in another category from ability.combat")


func _test_late_and_messy() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"ability.combat.melee"])
	var before := TagRegistry.get_tag_count()
	var late := TagRegistry.mask_of(&"stealth.hide") # undeclared: warns once, appended in a new category
	_check(late != 0 and TagRegistry.get_tag_count() == before + 2, "undeclared tag is added at runtime (with its parent)")
	_check(TagRegistry.get_categories() == [&"ability", &"stealth"], "...in a category of its own, after the declared ones")
	_check(TagRegistry.bit_of(&"ability.combat") == 1, "late tags never move existing bits")
	_check(TagRegistry.normalize(&" ability.combat..melee ") == &"ability.combat.melee", "messy names are cleaned up")
	_check(TagRegistry.mask_of(&"ability.combat..melee") == TagRegistry.mask_of(&"ability.combat.melee"), "messy name gives the same mask")


# 64 levels per category; another category still has its own 64.
func _test_limit() -> void:
	TagRegistry.reset(false)
	var many: Array = [&"other.x"]
	for i in 70:
		many.append(StringName("big.t%02d" % i))
	TagRegistry.declare(many)
	_check(TagRegistry.get_tag_count() == 64 + 2, "only 64 levels of a category get bits (big and t00 to t62); other has its own")
	_check(TagRegistry.own_bit(&"big.t62") == 1 << 63, "bit 63 works (the sign bit)")
	_check(TagRegistry.own_bit(&"big.t69") == 0, "tag past the limit: no bit of its own")
	_check(not TagRegistry.matches(-1, &"big.t69"), "tag past the limit matches nothing, even against a full mask")
	_check(TagRegistry.own_bit(&"other.x") == 1 << 1, "another category isn't affected by one that's full")


func _test_redirects_and_deprecation() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"ability.combat.melee", &"ability.combat.old_swing"])
	TagRegistry.declare_redirects({&"combat.melee": &"ability.combat.melee"})
	TagRegistry.declare_deprecated([&"ability.combat.old_swing"])
	_check(TagRegistry.normalize(&"combat.melee") == &"ability.combat.melee", "an old name is read as its new name (warns once)")
	_check(TagRegistry.mask_of(&"combat.melee") == TagRegistry.mask_of(&"ability.combat.melee") and not TagRegistry.has_tag(&"combat"), "...with the new name's mask, and the old name gets no bit")
	_check(TagRegistry.is_deprecated(&"ability.combat.old_swing") and TagRegistry.own_bit(&"ability.combat.old_swing") != 0, "a deprecated tag still works (warns once)")


func _test_declarations_file() -> void:
	TagRegistry.reset() # reads res://assets/scripts/resources/tag_declarations.tres
	_check(TagRegistry.get_tags().has(&"ability.movement.walk") and TagRegistry.get_tags().has(&"ability.movement"), "declarations file is read at first use")
	_check(TagRegistry.get_categories() == [&"ability", &"ai", &"effect", &"event", &"nav", &"status"], "the base categories (%s)" % [TagRegistry.get_categories()]) # Claude 2026-11-24: event (gameplay events, pawn spec 16.9)
	_check(TagRegistry.normalize(&"combat.melee") == &"ability.combat.melee" and TagRegistry.normalize(&"point.cover") == &"nav.point.cover", "the file's redirects read the old names")
	var undescribed: Array[StringName] = []
	for tag in TagRegistry.get_tags():
		if TagRegistry.description_of(tag) == "":
			undescribed.append(tag)
	_check(undescribed.is_empty(), "every declared tag has a description (missing: %s)" % [undescribed])
	# Claude 2026-11-10: the dropdown's list, and the Tags constants (typo protection).
	TagRegistry.reset()
	var listed := TagRegistry.read_declared_tags()
	_check(listed.has(&"ability.movement.dash") and listed.has(&"ability.movement") and listed.has(&"status"), "read_declared_tags lists the declared tags and their parent levels (%d)" % listed.size())
	_check(TagRegistry.read_declared_tags([&"nav"]).has(&"nav.point.cover") and not TagRegistry.read_declared_tags([&"nav"]).has(&"ability"), "...or only some categories'")
	var sorted := listed.duplicate()
	sorted.sort_custom(func(a, b): return String(a) < String(b))
	_check(listed == sorted, "in sorted order")
	# Reading it numbered nothing: a category declared after it still sorts in first (word 0), as before the registry is in use.
	TagRegistry.declare([&"aaa.from_code"])
	_check(not TagRegistry.read_declared_tags().has(&"aaa.from_code") and TagRegistry.word_of(&"aaa") == 0, "it only reads the file: it adds nothing and numbers nothing")
	TagRegistry.reset()
	var undeclared: Array[String] = []
	var misnamed: Array[String] = []
	var count := 0
	var groups: Dictionary = Tags.new().get_script().get_script_constant_map()
	for group_name: String in groups:
		var group = groups[group_name]
		if not group is GDScript:
			continue
		var category := StringName(group_name.to_lower())
		var constants: Dictionary = (group as GDScript).get_script_constant_map()
		for constant_name: String in constants:
			var tag: StringName = constants[constant_name]
			count += 1
			if not listed.has(tag):
				undeclared.append("%s.%s (%s)" % [group_name, constant_name, tag])
			var expected := String(category) if constant_name == "ALL" else String(category) + "." + constant_name.to_lower().replace("_", ".")
			if String(tag) != expected and String(tag).replace("_", ".") != expected:
				misnamed.append("%s.%s" % [group_name, constant_name])
	_check(count >= 50 and undeclared.is_empty(), "every Tags constant is a declared tag (%d constants; not declared: %s)" % [count, ", ".join(undeclared)])
	_check(misnamed.is_empty(), "and each constant's name matches its tag, in the group of its category (%s)" % ", ".join(misnamed))


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
