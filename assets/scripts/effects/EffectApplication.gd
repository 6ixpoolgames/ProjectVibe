## Written by Claude (claude-opus-5-5), 2026-11-10: one effect being applied once: what, to whom, from whom, and what came of it. Made by
## the EffectManager and handed to each do-once part in turn (EffectPart.apply_once). Pawn spec 8.11.
##
## Plain data, made on the authority only, and thrown away afterwards.
class_name EffectApplication
extends RefCounted

## The effect being applied.
var effect: Effect = null
## The pawn it's applied to.
var target: Pawn = null
## Who applied it, for memory, sensing, lifesteal and kill credit. Can be the target itself, or null (a trap made in code).
var source: Pawn = null
## The ability that applied it, or null.
var source_ability: AbilityBase = null
## The hit it came with, or null (an ability's start, a period of a poison, or code).
var hit: HitInfo = null
## How many stacks it has (Effect.Stacking.ADD_STACK). Parts multiply their amounts by this.
var stacks := 1
## The target's resistance to it, from 0 (none) to just under 1; below 0 is a weakness. A StatChangePart takes this fraction off
## harmful changes. Always 0 for an effect that isn't harmful.
var resistance := 0.0
## Health this application has taken so far, filled in by StatChangeParts; LifestealPart reads it.
var damage_dealt := 0.0
