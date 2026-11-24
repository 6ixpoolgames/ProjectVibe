# Written by Claude (claude-fable-5-2), 2026-11-16. History: effects/CHANGELOG.md.
## What all the modifiers on one pawn add up to right now.
##
## The pawn's [StatusManager] makes one whenever its list of effects changes and asks every modifier to add itself
## ([method EffectModifier.add_held]), so a new kind of modifier needs no change to the manager.
class_name ModifierTotals
extends RefCounted

## Stat name -> [added, multiplied, overrides, override value]: the stat's value becomes base_value x multiplied + added, or the
## override value when one overrides (the last added wins).
var stat_changes: Dictionary = {}
## One list per AbilityModifier.Number, of [ability tag bit, amount] pairs.
var ability_bonuses: Array = [[], [], []]
## [effect tag bit, amount] pairs: how much of each kind of effect the pawn shrugs off.
var resistance_bits: Array = []
## The parries held now ([ParryModifier]), which the hit ability asks.
var parries: Array[ParryModifier] = []


## Adds to a stat: added counts once per stack, multiplied is applied once per stack.
func change_stat(stat: StringName, added: float, multiplied: float, stacks: int) -> void:
	var change: Array = stat_changes.get(stat, [0.0, 1.0, false, 0.0])
	change[0] += added * stacks
	change[1] *= pow(multiplied, stacks)
	stat_changes[stat] = change


## Sets a stat to a value whatever its base and other modifiers. A later call wins over an earlier one.
func override_stat(stat: StringName, value: float) -> void:
	var change: Array = stat_changes.get(stat, [0.0, 1.0, false, 0.0])
	change[2] = true
	change[3] = value
	stat_changes[stat] = change
