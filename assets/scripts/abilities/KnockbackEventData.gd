# Written by Claude (claude-opus-5-5), 2026-11-24. History: abilities/CHANGELOG.md.
## What a knockback event carries: the push's start values (pawn spec 16.7).
##
## A [KnockbackEffector] sends it to the pawn it pushes as [code]event.reaction.knockback[/code], and the pawn's [KnockbackAbility]
## starts from it, reading the push before it starts. instigator is who pushed; optional_object is the hit, if one did it.
class_name KnockbackEventData
extends GameplayEventData

## The push at its start, flat, in metres per second.
var push_velocity := Vector3.ZERO
## How many ticks the push lasts, at the match's rate.
var push_ticks := 0
## How fast it lifts a grounded pawn, in metres per second. 0: no hop.
var hop_speed := 0.0
