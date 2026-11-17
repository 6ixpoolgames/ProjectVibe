# Written by Claude (claude-opus-5-5), 2026-11-07. History: stats/CHANGELOG.md.
## One number about a pawn, such as how fast it walks. A child of the pawn's StatManager.
##
## Pawn spec section 9. The stat's name is this node's name, such as MoveSpeed or JumpVelocity. Abilities and behaviours ask the
## StatManager for a stat by that name, and use a fallback of their own if there's none, so a missing stat is never a crash.
## [br]
## Its [member value] is [member base_value] plus what held effects add, times what they multiply ([method set_modifiers], from the
## EffectManager).
## [br]
## A stat that changes during play, such as Health, has [member changes_during_play] on. Then it also has a [member current] value,
## from 0 up to its value, which starts full, rolls back (the StatManager lists it with the pawn's TickStateComponent) and reaches
## clients in snapshots. Only the server changes it: [method StatManager.change_current].
## [br]
## With a [member table_column], the value is also copied into that column of the pawn table, for C++ to read.
class_name Stat
extends Node

## The value it starts with. Setting it works [member value] out again, keeping what effects add.
# GDScript note: "set(new_value):" under a variable runs every time it's assigned, including when the scene loads it.
@export var base_value := 0.0:
	set(new_value):
		base_value = new_value
		value = (base_value + _added) * _multiplied

## The value right now: [member base_value] with effects. A change tells the StatManager (its [member StatManager.version] goes up),
## so abilities that keep stat values read them again, and copies it into [member table_column] if there is one.
var value := 0.0:
	set(new_value):
		var changed := new_value != value # worked out before the assignment, for the table copy below
		if changed:
			var manager := get_parent() as StatManager
			if manager:
				manager.version += 1
		value = new_value
		if changed and table_column != &"":
			_push_to_table()

## The name of a pawn table column to copy this stat's value into whenever it changes, so C++ (the sensing job, say) reads it from
## the table instead of asking the pawn. Empty: not copied. The column must be a pushed one ([code]PawnTable.add_pushed_column[/code]),
## as the built-in "detectability" is, which the default Detectability stat fills. The table takes the new value at its next tick.
@export var table_column: StringName = &""

## On, this stat also has a [member current] value that goes up and down during play, such as Health. [member value] is then its
## most.
@export var changes_during_play := false
## With [member changes_during_play], how much there is now, from 0 to [member value]. Starts full. Rolls back.
# REFACTOR: other code writes current directly to refill or cap it (AbilityManager.revive, EffectManager, ArenaSample), so the
# "0 to value" rule lives in several places. A refill and cap on Stat or StatManager would keep it in one (reusable).
var current := 0.0


# What effects add to and multiply this stat by right now (set_modifiers). Kept here so a new base_value keeps them.
var _added := 0.0
var _multiplied := 1.0


## The effects on this stat, all together: [member value] becomes (base_value + added) x multiplied. 0 and 1 mean none. The pawn's
## EffectManager calls this whenever its held effects change.
func set_modifiers(added: float, multiplied: float) -> void:
	_added = added
	_multiplied = multiplied
	value = (base_value + _added) * _multiplied


func _init() -> void:
	set_process(false)
	set_physics_process(false)


# The value it starts with goes into the table too.
func _ready() -> void:
	if table_column != &"":
		_push_to_table()


# This stat's value into the pawn table's table_column, for the pawn it belongs to. Nothing happens without the C++ library (no
# table) or outside a pawn.
func _push_to_table() -> void:
	var manager := get_parent() as StatManager
	var table := Pawn.get_table()
	if manager and manager.pawn and table:
		table.set_value(manager.pawn, table_column, value)
