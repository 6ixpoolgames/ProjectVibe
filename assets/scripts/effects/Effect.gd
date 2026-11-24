# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## One effect, such as a sword hit, a poison or a combo boost: what it does to the pawn it's applied to.
##
## A Resource, saved as a .tres and tuned in one place however many abilities use it. Instant (duration 0) runs its [member parts] once;
## over time stays on the pawn for [member duration_ticks], its held parts holding and its do-once parts repeating each period.
## Parts run in list order. Apply one with [method StatusManager.apply_effect]; do-once parts run on the authority only, held parts on
## every machine.
## Design: pawn spec 8.11.
class_name Effect
extends Resource

## How a second application of the same effect, on the same pawn, combines with the one already there.
enum Stacking {
	REFRESH,   ## its time starts again; it stays one stack
	ADD_STACK, ## one more stack up to max_stacks, and its time starts again; each stack adds its parts' amounts again
	IGNORE,    ## the one already there carries on, and the new one does nothing
}

## A name for readouts and the debug timeline; also how a client recognises an effect made in code (a saved one goes by its path).
@export var effect_name: StringName = &""
## What kind of effect it is, as effect tags ([code]Tags.EFFECT[/code]) such as effect.damage.elemental.fire. Resistances and removing by tag go by these.
@export var tags: Array[StringName] = []
## On: resistances apply and invulnerability (a dash) stops it. Off: it helps, and gets through both.
@export var is_harmful := true
## Ticks at 60 a second it lasts. 0: instant.
@export_range(0, 36000, 1, "or_greater") var duration_ticks := 0
## Over time: its do-once parts run when first applied, then every this many ticks at 60 a second. 0: only when first applied.
@export_range(0, 3600, 1, "or_greater") var period_ticks := 0
## What a second application on the same pawn does.
@export var stacking := Stacking.REFRESH
## With ADD_STACK: the most stacks it can have.
@export_range(1, 99, 1, "or_greater") var max_stacks := 1
## What it does, in order.
@export var parts: Array[EffectPart] = []

# Every over-time effect seen on this machine, by id, so an id a rollback or snapshot loads into a pawn's active list finds its effect.
static var _by_id := {}
var _id := 0
var _mask := -1 # its tags as one mask, parents included; -1 until first worked out


## True if it's instant: it does its parts once and isn't kept.
func is_instant() -> bool:
	return duration_ticks <= 0


## Its tags as one mask, parents included ([method TagRegistry.full_mask_of_list]), worked out once.
func get_tag_mask() -> int:
	if _mask < 0:
		_mask = TagRegistry.full_mask_of_list(tags)
	return _mask


## True if it has this tag, or a tag inside it: an effect tagged effect.damage.elemental.fire has effect.damage.elemental.
func has_tag(tag: StringName) -> bool:
	return TagRegistry.has_tag(tag) and get_tag_mask() & TagRegistry.own_bit(tag) != 0


## True if any of its parts hold while it lasts.
func has_held_parts() -> bool:
	for part in parts:
		if part and part.is_held():
			return true
	return false


## How much its StatChangeParts change a stat in one go, before resistances; damage is negative. For readouts before a hit lands.
func planned_change(stat: StringName) -> float:
	var total := 0.0
	for part in parts:
		if part is StatChangePart and part.stat == stat:
			total += part.amount
	return total


## The number a pawn's active list stores for this effect, the same on every machine: a hash of its file path, else its effect_name. Never 0.
func get_id() -> int:
	if _id == 0:
		var key := resource_path if resource_path != "" else String(effect_name)
		if key == "":
			key = "unnamed effect %d" % get_instance_id() # differs between machines, so offline only
		# hash() is 32-bit; the mask keeps it positive.
		var number := key.hash() & 0x7FFFFFFF
		_id = number if number != 0 else 1
	return _id


## Makes this effect findable by its id on this machine. Two different effects with the same id is an error: rename one.
## The AbilityManager registers every effect its abilities can apply; the StatusManager registers any other it's given.
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


## An instant effect that takes this much Health, for hits made in code (a trap, a test). Tagged effect.damage.physical unless given tags.
static func make_damage(amount: float, damage_tags: Array[StringName] = [Tags.EFFECT.DAMAGE_PHYSICAL]) -> Effect:
	var effect := Effect.new()
	effect.effect_name = &"damage"
	effect.tags = damage_tags
	var part := StatChangePart.new()
	part.stat = StatusManager.HEALTH
	part.amount = -absf(amount)
	effect.parts = [part]
	return effect


## An instant effect that pushes the pawn along the hit's direction, for hits made in code. ticks are written for 60 a second.
static func make_knockback(speed: float, ticks: int, hop := 0.0) -> Effect:
	var effect := Effect.new()
	effect.effect_name = &"knockback"
	var part := KnockbackPart.new()
	part.speed = speed
	part.ticks = ticks
	part.hop_speed = hop
	effect.parts = [part]
	return effect
