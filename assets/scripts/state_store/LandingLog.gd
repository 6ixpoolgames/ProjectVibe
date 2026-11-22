# Written by Claude (claude-opus-5-5), 2026-11-22. History: state_store/CHANGELOG.md.
## The record of what landed on which tick: work done off the tick (a terrain chunk, a nav tile) that became part of play.
##
## Each landing is (tick, kind, key): a chunk published by the [ChunkStreamer], a tile committed by the NavServer (noted by the
## [TerrainNavFeeder]). Work lands on a landing tick fixed when it was asked for (state store spec 13.12), so the same start gives the
## same record on every run; the determinism check adds each tick's landings to its fingerprint, and an input-based replay can land
## the same work on the same ticks from it. Keeps the last [constant KEEP_TICKS] ticks. A static class: nothing to add to a scene.
class_name LandingLog
extends RefCounted

## Ticks of landings kept.
const KEEP_TICKS := 1200
## A terrain chunk published (key: [method chunk_key]).
const CHUNK := &"chunk"
## A nav tile committed (key: (x << 32) | z, as NavServer gives it).
const NAV_TILE := &"nav_tile"

static var _by_tick := {} # tick -> Array of [kind, key], in landing order
static var _oldest := -1


## Notes that something landed on this tick.
static func note(kind: StringName, key: int, tick: int) -> void:
	if not _by_tick.has(tick):
		_by_tick[tick] = []
		if _oldest < 0:
			_oldest = tick
		while _oldest >= 0 and _oldest < tick - KEEP_TICKS:
			_by_tick.erase(_oldest)
			_oldest += 1
	_by_tick[tick].append([kind, key])


## What landed on this tick, as [kind, key] pairs in landing order. Empty for a tick with none, or one no longer kept.
static func landings_at(tick: int) -> Array:
	return _by_tick.get(tick, [])


## A number that's the same on two runs only if the same things landed, in the same order, on this tick.
static func hash_at(tick: int) -> int:
	return hash(landings_at(tick))


## Forgets every landing. For tests and a new match.
static func clear() -> void:
	_by_tick.clear()
	_oldest = -1


## A terrain chunk's key as one number.
static func chunk_key(chunk: Vector2i) -> int:
	return (chunk.x << 32) | (chunk.y & 0xFFFFFFFF)
