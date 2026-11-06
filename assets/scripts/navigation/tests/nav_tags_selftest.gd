## Written by Claude (claude-opus-5-5), 2026-11-06: headless self-test for NavTags. Checks the odd cases listed at the top of NavTags.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/navigation/tests/nav_tags_selftest.tscn"
## It prints a few warnings on purpose, because some checks use undeclared tags.
extends Node

var _failures := 0


func _ready() -> void:
	print("--- Nav tags self-test ---")
	_test_bits_and_masks()
	_test_machines_agree()
	_test_search_from_first_level()
	_test_late_and_messy()
	_test_limit()
	_test_declarations_file()
	_test_missing_or_wrong_file()
	_test_separate_from_tag_registry()
	_test_handshake_covers_nav_tags()
	NavTags.reset() # leaves NavTags as the game would find it
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	# GDScript note: "a if condition else b" is how GDScript writes a choice inside one expression.
	get_tree().quit(0 if _failures == 0 else 1)


func _test_bits_and_masks() -> void:
	NavTags.reset(false) # false = don't read the file, so this test controls exactly which tags exist
	NavTags.declare([&"point.cover", &"link.jump", &"link.door.locked"])
	# Sorted levels: link, link.door, link.door.locked, link.jump, point, point.cover
	_check(NavTags.get_tags() == [&"link", &"link.door", &"link.door.locked", &"link.jump", &"point", &"point.cover"],
		"parent levels are added, and every level is numbered in sorted order")
	_check(NavTags.bit_of(&"link") == 0 and NavTags.bit_of(&"point.cover") == 5, "bit numbers follow the sorted order")

	var locked_door := NavTags.mask_of(&"link.door.locked")
	_check(locked_door == 0b111, "a mask holds the tag's own bit plus its parents'") # 0b writes a number in binary
	_check(NavTags.matches(locked_door, &"link"), "searching 'link' finds link.door.locked")
	_check(NavTags.matches(locked_door, &"link.door"), "searching 'link.door' finds link.door.locked")
	_check(not NavTags.matches(locked_door, &"link.jump"), "searching 'link.jump' doesn't find a door")
	_check(not NavTags.matches(NavTags.mask_of(&"point.cover"), &"link"), "searching 'link' doesn't find a point")

	var forbidden := NavTags.mask_of_list([&"link.door"])
	_check(locked_door & forbidden != 0, "forbidding link.door catches link.door.locked")
	_check(NavTags.mask_of(&"link.jump") & forbidden == 0, "forbidding link.door leaves link.jump alone")

	var capabilities := NavTags.full_mask_of_list([&"link.jump", &"point.cover"])
	var jump_link := NavTags.mask_of(&"link.jump")
	_check(jump_link & ~capabilities == 0, "a pawn's capabilities cover a link it can use (the nav spec's check)")
	_check(locked_door & ~capabilities != 0, "...and not one it can't")
	_check(NavTags.names_of(locked_door) == [&"link", &"link.door", &"link.door.locked"], "names_of lists the tags in a mask")

	_check(NavTags.mask_of(&"") == 0 and NavTags.bit_of(&"") == -1, "empty tag: no bit, mask 0")
	_check(not NavTags.matches(locked_door, &""), "an empty search matches nothing")
	_check(NavTags.mask_of(null) == 0, "null tag: mask 0, no error")


## Every machine must end up with the same bits, whatever order things happened in.
func _test_machines_agree() -> void:
	NavTags.reset(false)
	NavTags.declare([&"point.cover", &"link.jump", &"use.seat"])
	var first_hash := NavTags.content_hash()
	var first_bit := NavTags.bit_of(&"use.seat")
	NavTags.reset(false)
	NavTags.declare([&"use.seat", &"link.jump", &"point.cover"]) # different order, same tags
	_check(NavTags.bit_of(&"use.seat") == first_bit, "declaration order doesn't change the bits")
	_check(NavTags.content_hash() == first_hash, "same tags give the same content hash")
	NavTags.reset(false)
	NavTags.declare([&"use.seat", &"link.jump"])
	_check(NavTags.content_hash() != first_hash, "different tags give a different content hash")


func _test_search_from_first_level() -> void:
	NavTags.reset(false)
	NavTags.declare([&"link.jump", &"use.jump"])
	var jump_link := NavTags.mask_of(&"link.jump")
	_check(not NavTags.matches(jump_link, &"jump"), "searching 'jump' finds nothing: matching starts at the first level")
	_check(not NavTags.has_tag(&"jump"), "...and that search didn't add the tag")
	_check(not NavTags.matches(NavTags.mask_of(&"use.jump"), &"link"), "use.jump isn't inside link")


func _test_late_and_messy() -> void:
	NavTags.reset(false)
	NavTags.declare([&"link.jump"])
	var count_before := NavTags.get_tag_count()
	var late_mask := NavTags.mask_of(&"area.lava") # undeclared, so this warns once and adds it
	_check(late_mask != 0 and NavTags.get_tag_count() == count_before + 2, "an undeclared tag is added at runtime, with its parent")
	_check(NavTags.bit_of(&"link") == 0, "late tags never move existing bits")
	NavTags.declare([&"area.mud"]) # after use, so treated the same way
	_check(NavTags.has_tag(&"area.mud"), "declaring after use still adds the tag")
	_check(NavTags.bit_of(&"link") == 0, "...and still doesn't move existing bits")
	_check(NavTags.normalize(&" link..jump ") == &"link.jump", "messy names are cleaned up")
	_check(NavTags.mask_of(&"link..jump") == NavTags.mask_of(&"link.jump"), "a messy name gives the same mask")


func _test_limit() -> void:
	NavTags.reset(false)
	var many_tags: Array = []
	for number in 70:
		many_tags.append(StringName("t%02d" % number)) # "%02d" writes a number with two digits: t00, t01...
	NavTags.declare(many_tags)
	_check(NavTags.get_tag_count() == 64, "only 64 levels get bits")
	_check(NavTags.own_bit(&"t63") == 1 << 63, "bit 63 works (it's the sign bit, so the number looks negative)")
	_check(NavTags.mask_of(&"t69") == 0, "a tag past the limit has mask 0")
	_check(not NavTags.matches(-1, &"t69"), "a tag past the limit matches nothing, even against a mask of all ones") # -1 is all ones in binary


func _test_declarations_file() -> void:
	NavTags.reset() # reads res://assets/scripts/resources/nav_tag_declarations.tres
	var tags := NavTags.get_tags()
	_check(tags.has(&"link.jump") and tags.has(&"link"), "the declarations file is read on first use")
	_check(tags.has(&"area.road") and tags.has(&"obstacle.crate") and tags.has(&"point.cover") and tags.has(&"use.seat"), "the file declares all the tier 0 marker kinds")
	_check(NavTags.get_tag_count() == 22, "those tags take 22 of the 64 bits")


func _test_missing_or_wrong_file() -> void:
	var setting := NavTags.DECLARATIONS_SETTING
	ProjectSettings.set_setting(setting, "res://no_such_file.tres")
	NavTags.reset()
	_check(NavTags.get_tag_count() == 0, "no declarations file: no tags, no error")
	_check(NavTags.mask_of(&"link.jump") != 0, "...and tags still work, as undeclared ones")
	ProjectSettings.set_setting(setting, "res://terrain_sample.tscn") # a real file of the wrong kind
	NavTags.reset()
	_check(NavTags.get_tag_count() == 0, "a file of the wrong kind: warns, no tags, no error")
	# Claude 2026-11-06: null removes the setting again, so this test leaves nothing behind.
	ProjectSettings.set_setting(setting, null)


## The whole point of NavTags: abilities and navigation can't use up each other's bits.
func _test_separate_from_tag_registry() -> void:
	TagRegistry.reset()
	var ability_tags_before := TagRegistry.get_tags()
	NavTags.reset()
	NavTags.mask_of(&"link.brand_new") # an undeclared nav tag
	_check(TagRegistry.get_tags() == ability_tags_before, "adding a nav tag doesn't touch TagRegistry")
	_check(not NavTags.has_tag(&"combat.melee"), "ability tags aren't nav tags")
	_check(not TagRegistry.has_tag(&"link.jump"), "nav tags aren't ability tags")
	TagRegistry.reset()


## A release can set a build id, which skips reading the files, so the handshake must include nav tags itself.
func _test_handshake_covers_nav_tags() -> void:
	NavTags.reset(false)
	NavTags.declare([&"link.jump"])
	NetworkSession._hash_is_cached = false # the hash is normally kept, so this makes it work it out again
	var first_hash := NetworkSession.content_hash()
	NavTags.reset(false)
	NavTags.declare([&"link.climb"])
	NetworkSession._hash_is_cached = false
	_check(NetworkSession.content_hash() != first_hash, "the multiplayer content hash changes when nav tags differ")
	NetworkSession._hash_is_cached = false


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
