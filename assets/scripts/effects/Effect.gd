## Written by Claude (claude-opus-5-5), 2026-11-10: one effect, such as a sword hit, a poison or a combo boost: what it does to the pawn
## it's applied to. A Resource, so it's saved as a .tres file and tuned in one place, however many abilities use it. Pawn spec 8.11,
## the owner's design, shaped like Unreal's gameplay effects.
##
## Two kinds, by duration_seconds:
##   INSTANT    (0, the default) does its parts once and is gone: damage, a heal, a knockback, lifesteal.
##   OVER TIME  (above 0) stays on the pawn that long, in its EffectManager's active list, which rolls back. While it lasts, its held
##              parts hold (a slow, a resistance, a combo boost). With a period, its do-once parts run again every period (a poison
##              ticking, a heal over time).
##
## What it does is its parts, a list picked from a dropdown in the inspector (each an EffectPart):
##   do once  StatChangePart (Health -20 is damage, +15 a heal), KnockbackPart, LifestealPart
##   held     StatModifierPart (MoveSpeed x0.7), AbilityPriorityPart (a group of abilities' priority or interrupt numbers),
##            ResistancePart
## They run in list order, so a LifestealPart after a StatChangePart heals from the damage just dealt.
##
## Where effects come from: an ability's EffectApplier child (on start, to itself; on hit, to the target or itself), or code
## (pawn.effect_manager.apply_effect). The pawn they land on applies them to itself (EffectManager), with its own resistances, and an
## effect that pushes or staggers it goes through its own abilities, so its own interrupt rules decide (KnockbackPart).
##
## Who decides: do-once parts change things only on the authority (the server, or offline), as hits always have; clients get the
## results in snapshots. Held parts work on every machine, from the active list, so a client predicting its own pawn agrees.
##
## Odd cases (checked in effects/tests/effect_selftest.gd):
##   - No parts: it does nothing, and an over-time one still shows in the active list for its duration.
##   - Held parts on an instant effect: nothing to hold them, so they do nothing; a warning says so once.
##   - Saved over-time effects are recognised on every machine by their file path. One made in code needs an effect_name to be
##     recognised on a client; without one it works offline only.
class_name Effect
extends Resource

## How a second application of the same effect, on the same pawn, combines with the one already there.
enum Stacking {
	REFRESH,   ## its time starts again; it stays one stack
	ADD_STACK, ## one more stack, up to max_stacks, and its time starts again. Each stack adds its parts' amounts again
	IGNORE,    ## the one already there carries on, and the new one does nothing
}

## A name for readouts and the debug timeline. Also how a client recognises an effect made in code (one saved as a file goes by its
## path).
@export var effect_name: StringName = &""
## What kind of effect it is, as effect tags (EffectTags), such as damage.elemental.fire. Resistances and removing by tag go by
## these.
@export var tags: Array[StringName] = []
## On: it hurts. A pawn's resistances apply to it, and invulnerability (a dash) stops it. Off: it helps, and gets through both.
@export var is_harmful := true
## Seconds it lasts. 0: instant.
@export_range(0.0, 600.0, 0.05, "or_greater") var duration_seconds := 0.0
## For an over-time effect: its do-once parts run when it's first applied, then every this many seconds while it lasts. 0: only when
## first applied.
@export_range(0.0, 60.0, 0.05, "or_greater") var period_seconds := 0.0
@export var stacking := Stacking.REFRESH
## With ADD_STACK: the most stacks it can have.
@export_range(1, 99, 1, "or_greater") var max_stacks := 1
## What it does, in order.
@export var parts: Array[EffectPart] = []

# Every over-time effect seen on this machine, by id, so an id in a pawn's active list (which a rollback or a snapshot can load)
# finds its effect. GDScript note: a static var is one shared dictionary for the whole class.
static var _by_id := {}
var _id := 0
var _mask := -1 # its tags as one mask, parents included; -1 until first worked out


## True if it's instant: it does its parts once and isn't kept.
func is_instant() -> bool:
	return duration_seconds <= 0.0


## Its tags as one mask, parents included (EffectTags.full_mask_of_list), worked out once.
func get_tag_mask() -> int:
	if _mask < 0:
		_mask = EffectTags.full_mask_of_list(tags)
	return _mask


## True if it has this tag, or a tag inside it: an effect tagged damage.elemental.fire has damage.elemental.
func has_tag(tag: StringName) -> bool:
	return EffectTags.has_tag(tag) and get_tag_mask() & EffectTags.own_bit(tag) != 0


## True if any of its parts hold while it lasts.
func has_held_parts() -> bool:
	for part in parts:
		if part and part.is_held():
			return true
	return false


## How much it changes a stat by in one go, before resistances: its StatChangeParts for that stat added up. Damage is negative.
## For readouts, such as the swing's debug label, which shows a hit before it lands.
func planned_change(stat: StringName) -> float:
	var total := 0.0
	for part in parts:
		if part is StatChangePart and part.stat == stat:
			total += part.amount
	return total


## The number a pawn's active list stores for this effect. The same on every machine: from the file it's saved in, or else its
## effect_name. Never 0, which marks an empty entry.
func get_id() -> int:
	if _id == 0:
		var key := resource_path if resource_path != "" else String(effect_name)
		if key == "":
			key = "unnamed effect %d" % get_instance_id() # differs between machines, so offline only
		# GDScript note: hash() gives a 32-bit number; & 0x7FFFFFFF keeps it positive.
		var number := key.hash() & 0x7FFFFFFF
		_id = number if number != 0 else 1
	return _id


## Makes this effect findable by its id on this machine. The AbilityManager registers every effect its abilities can apply, which
## covers every pawn on every machine; EffectManager registers any other it's given. Two different effects with the same id is an
## error, said once: rename one (a file name, or an effect_name).
func register() -> void:
	var id := get_id()
	var known: Effect = _by_id.get(id)
	if known == null:
		_by_id[id] = self
	elif known != self:
		push_error("[Effect] '%s' and '%s' have the same id; one of them won't be recognised. Rename one." % [known.describe(), describe()])


## The registered effect with this id, or null.
static func find(id: int) -> Effect:
	return _by_id.get(id)


## A short name for readouts: effect_name, or the file's name.
func describe() -> String:
	if effect_name != &"":
		return String(effect_name)
	return resource_path.get_file().get_basename() if resource_path != "" else "effect"


## An instant effect that takes this much Health, for hits made in code (a trap, a test). Tagged damage.physical unless given tags.
static func make_damage(amount: float, damage_tags: Array[StringName] = [EffectTags.DAMAGE_PHYSICAL]) -> Effect:
	var effect := Effect.new()
	effect.effect_name = &"damage"
	effect.tags = damage_tags
	var part := StatChangePart.new()
	part.stat = &"Health"
	part.amount = -absf(amount)
	effect.parts = [part]
	return effect


## An instant effect that pushes the pawn along the hit's direction, for hits made in code. ticks are written for 60 ticks a second.
static func make_knockback(speed: float, ticks: int, hop := 0.0) -> Effect:
	var effect := Effect.new()
	effect.effect_name = &"knockback"
	var part := KnockbackPart.new()
	part.speed = speed
	part.ticks = ticks
	part.hop_speed = hop
	effect.parts = [part]
	return effect
