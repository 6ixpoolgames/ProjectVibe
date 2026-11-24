# Written by Claude (claude-opus-5-5), 2026-11-04. History: tags/CHANGELOG.md.
## The declared tags as named constants, grouped by category, so code can't misspell one.
##
## Write [code]Tags.ABILITY.MOVEMENT_DASH[/code] instead of [code]&"ability.movement.dash"[/code]: a misspelt constant is an error when
## the script is checked, where a misspelt name only gives a warning while playing ([TagRegistry] adds an undeclared tag on the spot).
## [br]
## One group per category (tag spec 2), named in capitals like the constants inside it ([code]Tags.EFFECT[/code]: a class named
## [code]Effect[/code] would clash with the Effect class). Inside a group, the names follow the tags without the category: dots become
## underscores, letters go upper case. [code]ALL[/code] is the category itself. Each tag's parent levels have constants too, because a
## lockout often names a whole branch ([code]Tags.ABILITY.MOVEMENT[/code] locks every movement ability).
## [br]
## For code only: designers pick tags from a dropdown (addons/tag_picker) and add new ones to resources/tag_declarations.tres. A
## constant here must be declared there (tags/tests/tag_registry_selftest checks); a declared tag needs a constant only if code uses it.
class_name Tags
extends RefCounted


## What an ability is: lockouts, cancels and the AI's action lookup go by these.
class ABILITY:
	const ALL := &"ability"
	const MOVEMENT := &"ability.movement"
	const MOVEMENT_WALK := &"ability.movement.walk"
	const MOVEMENT_SPRINT := &"ability.movement.sprint"
	const MOVEMENT_JUMP := &"ability.movement.jump"
	const MOVEMENT_DASH := &"ability.movement.dash"
	## A group: walk, sprint and jump are basic movement.
	const MOVEMENT_BASIC := &"ability.movement.basic"
	## A group: dash (and later a grappling hook) is advanced movement.
	const MOVEMENT_ADVANCED := &"ability.movement.advanced"

	const COMBAT := &"ability.combat"
	const COMBAT_MELEE := &"ability.combat.melee"
	const COMBAT_RANGED := &"ability.combat.ranged"
	const COMBAT_EVADE := &"ability.combat.evade"
	const COMBAT_KNOCKBACK := &"ability.combat.knockback"
	const COMBAT_PARRY := &"ability.combat.parry" # ParryAbility

	const UTILITY := &"ability.utility"
	const UTILITY_HEAL := &"ability.utility.heal"
	const UTILITY_INTERACT := &"ability.utility.interact"

	## Combo steps (pawn spec 8.11). A swing boosts the abilities tagged ability.combo.second for a moment, and the second swing
	## boosts ability.combo.finisher, so the next press picks them (AbilityModifier).
	const COMBO := &"ability.combo"
	const COMBO_SECOND := &"ability.combo.second"
	const COMBO_FINISHER := &"ability.combo.finisher"

	## The ability that plays out a pawn's death (DeathAbility).
	const DEATH := &"ability.death"

	## The hit ability (ReceiveHitAbility): its own category, which nothing locks out (pawn spec 16.7).
	const RECEIVE_HIT := &"ability.receive_hit"


## What an effect is: resistances, immunities and removing effects by kind go by these.
class EFFECT:
	const ALL := &"effect"
	const DAMAGE := &"effect.damage"
	const DAMAGE_PHYSICAL := &"effect.damage.physical"
	const DAMAGE_ELEMENTAL := &"effect.damage.elemental"
	const DAMAGE_ELEMENTAL_FIRE := &"effect.damage.elemental.fire"
	const DAMAGE_ELEMENTAL_FROST := &"effect.damage.elemental.frost"
	const DAMAGE_POISON := &"effect.damage.poison"
	const HEAL := &"effect.heal"
	const BUFF := &"effect.buff"
	const BUFF_COMBO := &"effect.buff.combo"
	const DEBUFF := &"effect.debuff"
	const DEBUFF_SLOW := &"effect.debuff.slow"


## What happened to an entity: gameplay events, sent with Pawn.send_event (pawn spec 16.9).
class EVENT:
	const ALL := &"event"
	const DAMAGE := &"event.damage"
	const DAMAGE_TAKEN := &"event.damage.taken" # StatusManager, when an effect takes Health
	const HEALTH := &"event.health"
	const HEALTH_DEPLETED := &"event.health.depleted" # Health's threshold at 0
	const HEALTH_LOW := &"event.health.low" # Health's threshold at 25%
	const HIT := &"event.hit"
	const HIT_TAKEN := &"event.hit.taken" # AbilityManager, as a hit is delivered: the hit ability starts
	const REACTION := &"event.reaction"
	const REACTION_KNOCKBACK := &"event.reaction.knockback" # KnockbackEffector: Knockback starts, with the push
	const REVIVED := &"event.revived" # AbilityManager.revive: charges refill


## A condition a pawn is in right now.
class STATUS:
	const ALL := &"status"
	const DEAD := &"status.dead"
	## An ability with limited uses has some left (AbilityDefinition.has_charges_tag).
	const HAS_AMMO := &"status.has_ammo"
	const HAS_AMMO_RANGED := &"status.has_ammo.ranged"
	## Parrying: hits from the front are blocked and answered (a ParryModifier on the effect says how).
	const PARRYING := &"status.parrying"
	## Hits are blocked (they arrive, so the AI notes them) and harmful effects refused: a dash's first ticks.
	const INVULNERABLE := &"status.invulnerable"
	## Hits are ignored completely, not even noticed: set pieces, scenery.
	const HIT_IMMUNE := &"status.hit_immune"


## The AI's own tags: its states and stances.
class AI:
	const ALL := &"ai"
	## The AI's state: the pawn owns one of these while its AI is in that state (AIStateBase.get_tag).
	const STATE := &"ai.state"
	const STATE_IDLE := &"ai.state.idle"
	const STATE_ALERT := &"ai.state.alert"
	const STATE_COMBAT := &"ai.state.combat"
	## How a behaviour fights (its AIBehaviourBase.tags), so score modifiers can favour one style.
	const STANCE := &"ai.stance"
	const STANCE_MELEE := &"ai.stance.melee"
	const STANCE_RANGED := &"ai.stance.ranged"


## Navigation: what a place, link or marker is.
class NAV:
	const ALL := &"nav"
	const LINK := &"nav.link"
	const LINK_JUMP := &"nav.link.jump"
	const LINK_CLIMB := &"nav.link.climb"
	const LINK_DOOR := &"nav.link.door"
	const LINK_TELEPORT := &"nav.link.teleport"
	const AREA := &"nav.area"
	const AREA_ROAD := &"nav.area.road"
	const AREA_HAZARD := &"nav.area.hazard"
	const AREA_WATER := &"nav.area.water"
	const AREA_FORBIDDEN := &"nav.area.forbidden"
	const OBSTACLE := &"nav.obstacle"
	const OBSTACLE_CRATE := &"nav.obstacle.crate"
	const OBSTACLE_VEHICLE := &"nav.obstacle.vehicle"
	const POINT := &"nav.point"
	const POINT_COVER := &"nav.point.cover"
	const POINT_PATROL := &"nav.point.patrol"
	const POINT_AMBUSH := &"nav.point.ambush"
	const POINT_WANDER := &"nav.point.wander"
	const USE := &"nav.use"
	const USE_SEAT := &"nav.use.seat"
	const USE_WORK := &"nav.use.work"
	const USE_PICKUP := &"nav.use.pickup"
