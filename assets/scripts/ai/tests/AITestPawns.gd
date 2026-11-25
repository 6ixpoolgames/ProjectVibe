# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
## Test helpers for building AI pawns by hand: the AI's components sit under the pawn's AIManager (pawn spec 16.10 step 5b).
class_name AITestPawns
extends RefCounted


## The pawn's AIManager, made and added if it has none yet. Add the AI components a test builds to it before the pawn joins the tree,
## and PawnInitializer fills in the rest.
static func ai_of(pawn: Pawn) -> AIManager:
	var ai := pawn.get_node_or_null(^"AIManager") as AIManager
	if ai == null:
		ai = AIManager.new()
		ai.name = "AIManager"
		pawn.add_child(ai)
	return ai
