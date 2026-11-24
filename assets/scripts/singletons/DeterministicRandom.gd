# Written by Claude (claude-opus-5-5), 2026-11-24. History: singletons/CHANGELOG.md.
## Repeatable random numbers for gameplay: each roll is a hash of the match seed, a key, a tick and a salt (pawn spec 16.9).
##
## Nothing is stored, so a replayed or re-simulated tick rolls the same, skipping a roll never changes the next, and there's no
## generator state to save or send. The key is usually an entity number ([method EntityNumber.of]); the salt tells apart rolls made
## for different things in one tick. Use it instead of [code]randf()[/code] for anything that changes play. Debug tools that are meant
## to be random, and terrain noise, stay apart. A static class: nothing to add to a scene. Twin of [code]native/src/deterministic_random.h[/code].
## [codeblock]
## var roll := DeterministicRandom.unit(pawn.entity_number(), TickDriver.tick, MY_SALT)
## var spot: Node3D = DeterministicRandom.pick(points, pawn.entity_number(), TickDriver.tick, MY_SALT)
## [/codeblock]
class_name DeterministicRandom
extends RefCounted

## The match's seed, mixed into every roll. Set from the game mode ([member GameModeSingleton.match_seed]) before a match starts; it
## must be the same on every machine.
static var match_seed := 0


## A number from 0 up to (not including) 1.
static func unit(key: int, tick: int, salt: int = 0) -> float:
	return unit_seeded(match_seed, key, tick, salt)


## A number from -1 up to (not including) 1.
static func signed(key: int, tick: int, salt: int = 0) -> float:
	return unit_seeded(match_seed, key, tick, salt) * 2.0 - 1.0


## A number from [param from] up to (not including) [param to].
static func float_range(from: float, to: float, key: int, tick: int, salt: int = 0) -> float:
	return from + (to - from) * unit_seeded(match_seed, key, tick, salt)


## A whole number from [param from] to [param to], both included, as [code]randi_range[/code] gives. Spans above 16 million
## repeat some values, as the hash gives 24 bits.
static func int_range(from: int, to: int, key: int, tick: int, salt: int = 0) -> int:
	if to <= from:
		return from
	return from + mini(int(unit_seeded(match_seed, key, tick, salt) * (to - from + 1)), to - from)


## One of the items, or null if there are none.
static func pick(items: Array, key: int, tick: int, salt: int = 0) -> Variant:
	if items.is_empty():
		return null
	return items[int_range(0, items.size() - 1, key, tick, salt)]


## The roll itself, with a seed of its own: [method unit] uses the match seed. A small integer hash, not a generator. Each step stays
## within 32 bits so nothing overflows, and it gives 24 bits, so every value fits exactly in a float.
static func unit_seeded(seed_value: int, key: int, tick: int, salt: int) -> float:
	# Bit-for-bit twin of deterministic_random::unit in native/src/deterministic_random.h.
	var h := (seed_value * 83492791) ^ (key * 19349663) ^ (tick * 73856093) ^ salt
	h &= 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0
