# Written by Claude (claude-opus-5-5), 2026-11-10. History: tags/CHANGELOG.md.
## The declared ability tags as named constants, so code can't misspell one.
##
## Write [code]Tags.MOVEMENT_DASH[/code] instead of [code]&"movement.dash"[/code]: a misspelt constant is an error when the script is
## checked, where a misspelt name only gives a warning while playing (TagRegistry adds an undeclared tag on the spot).
## [br]
## The names follow the tags: dots become underscores, letters go upper case. Each tag's parent levels have constants too, because a
## lockout often names a whole branch ([code]Tags.MOVEMENT[/code] locks every movement tag).
## [br]
## For code only: designers pick tags from a dropdown (addons/tag_picker) and add new ones to resources/tag_declarations.tres. A
## constant here must be declared there (tags/tests/tag_registry_selftest checks); a declared tag needs a constant only if code uses it.
class_name Tags
extends RefCounted

const MOVEMENT := &"movement"
const MOVEMENT_WALK := &"movement.walk"
const MOVEMENT_SPRINT := &"movement.sprint"
const MOVEMENT_JUMP := &"movement.jump"
const MOVEMENT_DASH := &"movement.dash"
## A group: walk, sprint and jump are basic movement.
const MOVEMENT_BASIC := &"movement.basic"
## A group: dash (and later a grappling hook) is advanced movement.
const MOVEMENT_ADVANCED := &"movement.advanced"

const COMBAT := &"combat"
const COMBAT_MELEE := &"combat.melee"
const COMBAT_RANGED := &"combat.ranged"
const COMBAT_EVADE := &"combat.evade"
const COMBAT_KNOCKBACK := &"combat.knockback"
const COMBAT_PARRY := &"combat.parry" # ParryAbility

const UTILITY := &"utility"
const UTILITY_HEAL := &"utility.heal"
const UTILITY_INTERACT := &"utility.interact"

## Combo steps (pawn spec 8.11). A swing boosts the abilities tagged combo.second for a moment, and the second swing boosts
## combo.finisher, so the next press picks them (AbilityPriorityPart).
const COMBO := &"combo"
const COMBO_SECOND := &"combo.second"
const COMBO_FINISHER := &"combo.finisher"

const STATUS := &"status"
const STATUS_DEAD := &"status.dead"
