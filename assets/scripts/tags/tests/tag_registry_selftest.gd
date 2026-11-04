## Written by Claude (claude-opus-5-5), 2026-11-04: headless self-test for TagRegistry. Checks the corner cases listed at the top of TagRegistry.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/tags/tests/tag_registry_selftest.tscn"
extends Node

var _failures := 0


func _ready() -> void:
	print("--- Tag registry self-test ---")
	_test_bits_and_masks()
	_test_peers_agree()
	_test_level_search()
	_test_late_and_messy()
	_test_limit()
	_test_declarations_file()
	TagRegistry.reset() # leave the registry as the game would find it
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_bits_and_masks() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"movement.walk", &"combat.melee.sword", &"combat.ranged"])
	# Sorted levels: combat, combat.melee, combat.melee.sword, combat.ranged, movement, movement.walk
	_check(TagRegistry.get_tags() == [&"combat", &"combat.melee", &"combat.melee.sword", &"combat.ranged", &"movement", &"movement.walk"],
		"parent levels added and every level numbered in sorted order")
	_check(TagRegistry.bit_of(&"combat") == 0 and TagRegistry.bit_of(&"movement.walk") == 5, "bit indices follow the sorted order")

	var sword := TagRegistry.mask_of(&"combat.melee.sword")
	_check(sword == 0b111, "mask holds the tag's own bit plus its parents'")
	_check(TagRegistry.matches(sword, &"combat"), "query 'combat' matches combat.melee.sword")
	_check(TagRegistry.matches(sword, &"combat.melee"), "query 'combat.melee' matches combat.melee.sword")
	_check(not TagRegistry.matches(sword, &"combat.ranged"), "query 'combat.ranged' doesn't match a sword")
	_check(not TagRegistry.matches(TagRegistry.mask_of(&"movement.walk"), &"combat"), "movement doesn't match combat")

	var locked := TagRegistry.mask_of_list([&"combat.melee"])
	_check(sword & locked != 0, "locking combat.melee blocks combat.melee.sword")
	_check(TagRegistry.mask_of(&"combat.ranged") & locked == 0, "locking combat.melee leaves combat.ranged free")
	_check(TagRegistry.mask_of(&"combat.ranged") & TagRegistry.mask_of_list([&"combat"]) != 0, "locking combat blocks all of combat")

	var dash := TagRegistry.category_mask_of_list([&"movement.walk", &"combat.melee"])
	_check(TagRegistry.matches(dash, &"movement") and TagRegistry.matches(dash, &"combat"), "category + extra_categories answer to both")
	_check(TagRegistry.names_of(sword) == [&"combat", &"combat.melee", &"combat.melee.sword"], "names_of lists the tags in a mask")

	_check(TagRegistry.mask_of(&"") == 0 and TagRegistry.bit_of(&"") == -1, "empty tag: no bit, mask 0")
	_check(not TagRegistry.matches(sword, &""), "empty query matches nothing")
	_check(TagRegistry.mask_of(null) == 0, "null tag: mask 0, no error")


func _test_peers_agree() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"movement.walk", &"combat.melee", &"utility.heal"])
	var hash_a := TagRegistry.content_hash()
	var bit_a := TagRegistry.bit_of(&"utility.heal")
	TagRegistry.reset(false)
	TagRegistry.declare([&"utility.heal", &"combat.melee", &"movement.walk"]) # different order, same content
	_check(TagRegistry.bit_of(&"utility.heal") == bit_a, "declaration order doesn't change bits (peers agree)")
	_check(TagRegistry.content_hash() == hash_a, "content hash equal for equal declarations")
	TagRegistry.reset(false)
	TagRegistry.declare([&"utility.heal", &"combat.melee"])
	_check(TagRegistry.content_hash() != hash_a, "content hash differs for different declarations")


## Claude 2026-11-04: the any-level search was removed from tier 0; only root matching remains.
func _test_level_search() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"combat.melee.sword", &"crafting.smithing.sword"])
	var sword := TagRegistry.mask_of(&"combat.melee.sword")
	_check(not TagRegistry.matches(sword, &"sword"), "root search for 'sword' finds nothing")
	_check(not TagRegistry.has_tag(&"sword"), "...and querying an unknown tag doesn't add it")
	_check(not TagRegistry.matches(TagRegistry.mask_of(&"crafting.smithing.sword"), &"combat"), "crafting.smithing.sword isn't combat")


func _test_late_and_messy() -> void:
	TagRegistry.reset(false)
	TagRegistry.declare([&"combat.melee"])
	var before := TagRegistry.get_tag_count()
	var late := TagRegistry.mask_of(&"stealth.hide") # undeclared: warns once, appended
	_check(late != 0 and TagRegistry.get_tag_count() == before + 2, "undeclared tag is added at runtime (with its parent)")
	_check(TagRegistry.bit_of(&"combat") == 0, "late tags never move existing bits")
	_check(TagRegistry.normalize(&" combat..melee ") == &"combat.melee", "messy names are cleaned up")
	_check(TagRegistry.mask_of(&"combat..melee") == TagRegistry.mask_of(&"combat.melee"), "messy name gives the same mask")


func _test_limit() -> void:
	TagRegistry.reset(false)
	var many: Array = []
	for i in 70:
		many.append(StringName("t%02d" % i))
	TagRegistry.declare(many)
	_check(TagRegistry.get_tag_count() == 64, "only 64 levels get bits")
	_check(TagRegistry.own_bit(&"t63") == 1 << 63, "bit 63 works (the sign bit)")
	_check(TagRegistry.mask_of(&"t69") == 0, "tag past the limit: mask 0")
	_check(not TagRegistry.matches(-1, &"t69"), "tag past the limit matches nothing, even against a full mask")


func _test_declarations_file() -> void:
	TagRegistry.reset() # reads res://assets/scripts/resources/tag_declarations.tres
	_check(TagRegistry.get_tags().has(&"movement.walk") and TagRegistry.get_tags().has(&"movement"), "declarations file is read at first use")
	_check(TagRegistry.get_tags().has(&"combat.melee"), "file declares the prototype ability categories")


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
