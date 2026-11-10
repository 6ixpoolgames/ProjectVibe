## Written by Claude (claude-opus-5-5), 2026-11-10: the declared tags as named constants, so code can't misspell one. The owner's request
## (typo protection). Write Tags.MOVEMENT_DASH instead of &"movement.dash": a misspelt constant is an error when the script is checked,
## where a misspelt name only gave a warning while playing (TagRegistry adds an undeclared tag on the spot).
##
## The names follow the tags: dots become underscores, letters go upper case. Each tag's parent levels have constants too, because
## a lockout often names a whole branch (Tags.MOVEMENT locks every movement tag).
##
## This is for code only. Designers pick tags in the inspector from a dropdown (addons/tag_picker), and add new ones to the
## declarations file (resources/tag_declarations.tres) without touching this. A constant here must be declared there:
## tags/tests/tag_registry_selftest checks it. A tag declared there needs a constant here only if code uses it.
##
## GDScript note: a script with only constants is never instantiated; Tags.MOVEMENT is read straight from the class.
class_name Tags
extends RefCounted

const MOVEMENT := &"movement"
const MOVEMENT_WALK := &"movement.walk"
const MOVEMENT_SPRINT := &"movement.sprint"
const MOVEMENT_JUMP := &"movement.jump"
const MOVEMENT_DASH := &"movement.dash"
## Claude 2026-11-10: groups. Walk, sprint and jump are basic; dash (and later a grappling hook) is advanced.
const MOVEMENT_BASIC := &"movement.basic"
const MOVEMENT_ADVANCED := &"movement.advanced"

const COMBAT := &"combat"
const COMBAT_MELEE := &"combat.melee"
const COMBAT_RANGED := &"combat.ranged"
const COMBAT_EVADE := &"combat.evade"
const COMBAT_KNOCKBACK := &"combat.knockback"

const UTILITY := &"utility"
const UTILITY_HEAL := &"utility.heal"
const UTILITY_INTERACT := &"utility.interact"

## Claude 2026-11-10: combo steps (pawn spec 8.11). A swing boosts the abilities tagged combo.second for a moment, and the second swing
## boosts combo.finisher, so the next press picks them (AbilityPriorityPart).
const COMBO := &"combo"
const COMBO_SECOND := &"combo.second"
const COMBO_FINISHER := &"combo.finisher"

const STATUS := &"status"
const STATUS_DEAD := &"status.dead"
