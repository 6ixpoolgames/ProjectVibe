# Written by Claude (claude-opus-5-5), 2026-11-07. History: resources/CHANGELOG.md.
## The parts every pawn gets unless its own scene already has one of the same name, and other game-wide pawn settings.
##
## PawnInitializer reads this (pawn spec section 11). One file per game (resources/pawn_defaults.tres), so a designer changes every
## pawn's defaults in one place.
## [br]
## Each part is a small scene, so its settings can be changed in the editor. A part's name is its scene's root node name, and a pawn
## that has a child with that name keeps its own. Parts are added in this list's order, the same on every machine. A part's
## components (children its scene instances from scenes of their own, like the AIManager's) are filled in the same way.
extends Resource
class_name PawnDefaultsRes

## The default parts, in the order they're added.
@export var parts: Array[PackedScene] = []
## The AI brain a pawn gets when its own scene has none: an AIBehaviourManager scene with its behaviours as children (a behaviour
## set the manager scores and picks between, not a behaviour tree). Used instead of the AIManager's behaviour-less one, and a
## player's pawn gets it too: its AI waits while a player has it and takes over when they let go. Empty: the parts list's.
@export var ai_brain: PackedScene
## How far a pawn that keeps the world loaded (a player's, or one whose PawnStreamingSource has keeps_world_loaded on) loads ground around it, in metres.
@export_range(0.0, 2000.0, 1.0, "or_greater") var world_load_distance := 320.0
## How far nav is built around such a pawn, in metres. Building nav as far out as the ground would be slow (about 100 tiles a chunk),
## so it's shorter. 0 builds none. It can't exceed world_load_distance.
@export_range(0.0, 2000.0, 1.0, "or_greater") var world_nav_distance := 128.0
