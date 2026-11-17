# Written by Claude (claude-fable-5-2), 2026-11-16. History: effects/CHANGELOG.md.
## What all the held parts on one pawn add up to right now.
##
## The pawn's [EffectManager] makes one whenever its list of effects changes, and asks every held part to add itself
## ([method EffectPart.add_held]). So a new kind of held part overrides add_held and adds to one of these, with no change to the
## manager.
class_name EffectHeldTotals
extends RefCounted

## Stat name -> [added, multiplied]: the stat's value becomes (base_value + added) x multiplied.
var stat_changes: Dictionary = {}
## One list per AbilityPriorityPart.Number, of [ability tag bit, amount] pairs.
var ability_bonuses: Array = [[], [], []]
## [effect tag bit, amount] pairs: how much of each kind of effect the pawn shrugs off.
var resistance_bits: Array = []


## Adds to a stat: added counts once per stack, multiplied is applied once per stack.
func change_stat(stat: StringName, added: float, multiplied: float, stacks: int) -> void:
	var change: Array = stat_changes.get(stat, [0.0, 1.0])
	change[0] += added * stacks
	change[1] *= pow(multiplied, stacks)
	stat_changes[stat] = change
