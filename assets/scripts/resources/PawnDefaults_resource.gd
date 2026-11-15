## Written by Claude (claude-opus-5-5), 2026-11-07: the parts every pawn gets unless its own scene already has one of the same name.
## PawnInitializer reads this. Pawn spec section 11. One file per game, so a designer changes every pawn's defaults in one place.
##
## Each part is a small scene, so its settings can be changed in the editor. A part's name is its scene's root node name, and a pawn
## that has a child with that name keeps its own. Parts are added in this list's order, the same on every machine.
extends Resource
class_name PawnDefaultsRes

## The default parts, in the order they're added.
@export var parts: Array[PackedScene] = []
## Claude 2026-11-16 (pawn M2): how far a pawn that keeps the world loaded (a player's, or one with keeps_world_loaded on) loads ground around
## it, in metres. A game-wide setting, the owner's call: it was a setting on each pawn.
@export_range(0.0, 2000.0, 1.0, "or_greater") var world_load_distance := 320.0
## How far nav is built around such a pawn, in metres. Building nav as far out as the ground would be slow (about 100 tiles a chunk),
## so it's shorter. 0 builds none. It can't exceed world_load_distance.
@export_range(0.0, 2000.0, 1.0, "or_greater") var world_nav_distance := 128.0
