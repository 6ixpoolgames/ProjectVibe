## Written by Claude (claude-opus-5-5), 2026-11-07: the parts every pawn gets unless its own scene already has one of the same name.
## PawnInitializer reads this. Pawn spec section 11. One file per game, so a designer changes every pawn's defaults in one place.
##
## Each part is a small scene, so its settings can be changed in the editor. A part's name is its scene's root node name, and a pawn
## that has a child with that name keeps its own. Parts are added in this list's order, the same on every machine.
extends Resource
class_name PawnDefaultsRes

## The default parts, in the order they're added.
@export var parts: Array[PackedScene] = []
