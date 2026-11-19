# Written by Claude (claude-opus-5-5), 2026-11-19. History: pawn/CHANGELOG.md.
## The one shared table of plain pawn data (the C++ PawnTable) and the grid built on it (AIPawnGrid), for AI sensing and swing hits.
##
## Every pawn in the tree has a row, keyed by its entity id. Pawns NetworkSession never configured, as in most tests, have no entity
## id; they get keys from [constant KEYS_WITHOUT_ID] up, after every networked pawn, in the order they joined. Both are null without
## the navcore library. Pawns join and leave it themselves ([method join], [method leave]); everyone else only reads it. The state
## store takes over this job when AI sensing moves onto it (state store spec 12.7). Design: scaling spec section 3.
class_name SharedPawnTable
extends RefCounted

## The first key handed to a pawn with no entity id.
const KEYS_WITHOUT_ID := 1 << 40

static var _table: Object = null
static var _grid: Object = null
static var _next_key := KEYS_WITHOUT_ID


## The shared table, or null without the C++ library. Its rows are read from the pawns once a tick, at the first refresh(tick).
static func get_table() -> Object:
	return _table


## The shared grid of pawns, built from the table on first use, or null without the C++ library. AI sensing and the swing hit checks
## (MeleeSweepStep) both use it.
static func get_grid() -> Object:
	if _grid == null and _table != null and ClassDB.class_exists(&"AIPawnGrid"):
		_grid = ClassDB.instantiate(&"AIPawnGrid")
		_grid.set_table(_table)
	return _grid


## Adds a pawn, making the table on first use. The key is its NetworkEntity's entity id (NetworkSession sets it before the pawn enters
## the tree), else the next key from [constant KEYS_WITHOUT_ID].
static func join(pawn: Node) -> void:
	if _table == null:
		if not ClassDB.class_exists(&"PawnTable"):
			return
		_table = ClassDB.instantiate(&"PawnTable")
	var key := -1
	for child in pawn.get_children():
		if child is NetworkEntity and child.entity_id >= 0:
			key = child.entity_id
	if key < 0:
		key = _next_key
		_next_key += 1
	_table.add(pawn, key)


## Takes a pawn out.
static func leave(pawn: Node) -> void:
	if _table:
		_table.remove(pawn)
