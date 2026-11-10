## Written by Claude (claude-opus-5-5), 2026-11-10: applies effects to its pawn and keeps the over-time ones (pawn spec 8.11). A part on
## the pawn, added by PawnInitializer, like the StatManager and AbilityManager. The owner's design: whatever hits a pawn hands it
## effects, and the pawn applies them to itself, with its own resistances, through its own stats and abilities.
##
## How to use it:
##   pawn.effect_manager.apply_effect(effect, source)   # source is who applied it (for memory, lifesteal), or null
##   pawn.effect_manager.has_effect(effect)              # is an over-time effect on the pawn now?
##   pawn.effect_manager.remove_with_tag(EffectTags.DEBUFF)   # a cleanse
##   pawn.effect_manager.resistances[EffectTags.DAMAGE_ELEMENTAL_FIRE] = 0.5   # set in the inspector, usually
## A hit (HitInfo) carries its ability's effects, and Pawn._take_hit hands them here (take_hit).
##
## Applying one, in order (apply_effect):
##   1. A dead pawn takes nothing. A harmful effect does nothing while the pawn is invulnerable (a dash), or if the pawn's resistance
##      to it is 1 or more (immune).
##   2. Instant: its do-once parts run now, on the authority only, and it's gone.
##   3. Over time: it goes in the active list (or, if it's there already, its stacking rule says what happens). The first time, its
##      do-once parts run now, on the authority only. Its held parts hold from now on, on every machine.
##   Do-once parts run in order; once Health reaches 0, the pawn dies (Pawn.health_ran_out) and the rest are skipped.
##   Health taken from a source adds threat in this pawn's AI memory for that source, as hits always did.
##
## Each tick (tick_effects, called by the pawn before its abilities run): every active effect's
## ticks count down, it ends at 0, and one with a period runs its do-once parts again when its period comes round. A poison of 3 s
## with a 1 s period runs at 0, 1 and 2 s. A pawn with effects on it doesn't rest (pawn spec 15.3).
##
## Rollback: the active list is one PackedInt64Array, active_effects, five numbers per effect: its id (Effect.get_id), ticks left,
## ticks to its next period, stacks, and its source (an entity id online, else an instance id). The pawn's TickStateComponent rolls
## it back and sends it in snapshots. Empty, which most pawns are, it costs almost nothing. What the held parts add up to (stat
## values, ability numbers, resistances) is worked out from the list whenever it changes, including when a rollback loads it, so it
## needn't roll back itself. It's worked out at once when this script changes the list, and on the next tick after a rollback
## loads one.
##
## Resistances: the inspector's resistances, plus every held ResistancePart, as effect tag -> amount. An effect's resistance is every
## one whose tag is one of the effect's tags or a level above one, added up: 0.2 against damage.elemental and 0.3 against
## damage.elemental.fire make 0.5 against a fire effect. Negative is a weakness. They apply only to harmful effects.
##
## Odd cases (checked in effects/tests/effect_selftest.gd):
##   - The list is full (max_active_effects): a new over-time effect is refused, with a warning once.
##   - An id in the list that this machine doesn't know (an effect made in code with no effect_name, on a client): it counts down,
##     and its held parts do nothing here, with a warning once.
##   - The pawn dies: everything in the list is removed (Pawn._die).
class_name EffectManager
extends Node

## Sent when an effect is applied, on every machine that applies it (do-once parts only ran if this is the authority).
signal effect_applied(effect: Effect, application: EffectApplication)
## Sent when an over-time effect ends or is removed.
signal effect_ended(effect: Effect)

## Numbers per entry in active_effects.
const STRIDE := 5
const ID := 0
const TICKS_LEFT := 1
const PERIOD_LEFT := 2
const STACKS := 3
const SOURCE := 4

## This pawn's own resistances, by effect tag: 0.25 takes a quarter off harmful effects with that tag; 1 or more ignores them;
## negative is a weakness. Held ResistanceParts add to these while they last.
@export var resistances: Dictionary[StringName, float] = {}
## The most over-time effects this pawn can have at once. A new one past this is refused.
@export_range(1, 64, 1, "or_greater") var max_active_effects := 16

## The active list, rolled back (see the top of the file). Five numbers per effect. Read it with get_active_effects() instead.
# GDScript note: the getter and setter make this a window onto _entries. The TickStateComponent reads and writes it through them,
# and the setter notices a rollback loading a list. This script changes _entries in place while counting down, which doesn't go
# through the setter, so the held parts are only worked out again when the list really changes.
var active_effects: PackedInt64Array:
	get:
		return _entries
	set(value):
		_entries = value
		_dirty = true

var pawn: Pawn = null

var _entries := PackedInt64Array()
var _dirty := true # the list changed: what the held parts add up to is worked out again before it's next used
# What the held parts add up to, worked out from the list (see _refresh):
var _stat_changes := {} # stat name -> [added, multiplied]
var _touched_stats := {} # stat names the held parts have changed, so they go back to their base when the parts end
var _ability_bonuses: Array = [[], [], []] # per AbilityPriorityPart.Number: [ability tag bit, amount] pairs
var _resistance_bits: Array = [] # [effect tag bit, amount] pairs, from resistances and held ResistanceParts
var _warned := {}


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn == null:
		push_warning("EffectManager: its parent isn't a Pawn, so it does nothing.")


# The active list rolls back: it's listed with the pawn's TickStateComponent before the first tick, as StatManager lists Health.
func _ready() -> void:
	if pawn == null:
		return
	var entries: Array[String] = ["%s:active_effects" % String(pawn.get_path_to(self))]
	for child in pawn.get_children():
		if child is TickStateComponent:
			child.add_state_properties(entries)
			break


# --- Applying ----------------------------------------------------------------------------------


## Applies an effect to this pawn (see the top of the file). source is who applied it, or null; source_ability and hit, if known,
## are handed to its parts. Returns false if it was refused (dead, invulnerable, immune, the list full, or IGNORE stacking).
func apply_effect(effect: Effect, source: Pawn = null, source_ability: AbilityBase = null, hit: HitInfo = null) -> bool:
	if effect == null or pawn == null or pawn.is_dead():
		return false
	var resistance := 0.0
	if effect.is_harmful:
		if pawn.is_invulnerable():
			return false
		resistance = resistance_to(effect)
		if resistance >= 1.0:
			return false # immune
	var application := EffectApplication.new()
	application.effect = effect
	application.target = pawn
	application.source = source
	application.source_ability = source_ability
	application.hit = hit
	application.resistance = resistance
	if effect.is_instant():
		if effect.has_held_parts():
			_warn_once("held:" + effect.describe(), "EffectManager: '%s' is instant, so its held parts do nothing. Give it a duration." % effect.describe())
		effect_applied.emit(effect, application)
		_run_once(application)
		return true
	effect.register()
	var first_time := false
	var at := _find(effect.get_id())
	if at >= 0:
		match effect.stacking:
			Effect.Stacking.IGNORE:
				return false
			Effect.Stacking.ADD_STACK:
				_entries[at + STACKS] = mini(_entries[at + STACKS] + 1, effect.max_stacks)
		_entries[at + TICKS_LEFT] = TickDriver.seconds_to_ticks(effect.duration_seconds)
		_entries[at + SOURCE] = _source_key(source)
	else:
		if _entries.size() / STRIDE >= max_active_effects:
			_warn_once("full", "EffectManager: %s already has %d effects on it (max_active_effects), so '%s' was refused." % [pawn.name, max_active_effects, effect.describe()])
			return false
		_entries.append_array([effect.get_id(), TickDriver.seconds_to_ticks(effect.duration_seconds),
				TickDriver.seconds_to_ticks(effect.period_seconds), 1, _source_key(source)])
		at = _entries.size() - STRIDE
		first_time = true
	_refresh() # at once, so the slow or boost holds from this moment
	application.stacks = int(_entries[at + STACKS])
	effect_applied.emit(effect, application)
	if first_time:
		_run_once(application)
	return true


## Applies several, in order, stopping if the pawn dies.
func apply_effects(effects: Array[Effect], source: Pawn = null, source_ability: AbilityBase = null, hit: HitInfo = null) -> void:
	for effect in effects:
		if pawn == null or pawn.is_dead():
			return
		apply_effect(effect, source, source_ability, hit)


## Called by Pawn._take_hit, on the authority: the hit's effects, from its attacker. Fills in hit.damage_dealt.
func take_hit(hit: HitInfo) -> void:
	var before := pawn.get_health()
	apply_effects(hit.effects, hit.attacker, hit.ability, hit)
	hit.damage_dealt = maxf(before - pawn.get_health(), 0.0)


# --- Each tick -----------------------------------------------------------------------------------


## The pawn calls this once per tick, before its abilities run, while the list has something in it. See the top of the file.
func tick_effects() -> void:
	if _dirty:
		_refresh() # a rollback loaded the list, perhaps an empty one, since the last tick
	if _entries.is_empty():
		return
	var due: Array = [] # [effect, stacks, source key] whose period came round this tick, run once the counting is done
	var ended: Array[Effect] = []
	var at := _entries.size() - STRIDE
	while at >= 0: # from the end, so removing one doesn't move the ones still to come
		_entries[at + TICKS_LEFT] -= 1
		var effect := Effect.find(_entries[at + ID])
		if _entries[at + TICKS_LEFT] <= 0:
			_remove_at(at)
			if effect:
				ended.append(effect)
		elif effect and effect.period_seconds > 0.0:
			_entries[at + PERIOD_LEFT] -= 1
			if _entries[at + PERIOD_LEFT] <= 0:
				_entries[at + PERIOD_LEFT] = TickDriver.seconds_to_ticks(effect.period_seconds)
				due.append([effect, int(_entries[at + STACKS]), _entries[at + SOURCE]])
		at -= STRIDE
	if not ended.is_empty():
		_refresh() # what ended stops holding before this tick's abilities run
	for effect in ended:
		effect_ended.emit(effect)
	if not pawn.is_authority():
		return # do-once parts are the authority's
	due.reverse() # in list order, oldest first
	for entry in due:
		if pawn.is_dead():
			return
		var effect: Effect = entry[0]
		if effect.is_harmful and pawn.is_invulnerable():
			continue # a dash dodges a poison's tick too
		var application := EffectApplication.new()
		application.effect = effect
		application.target = pawn
		application.source = _source_pawn(entry[2])
		application.stacks = entry[1]
		application.resistance = resistance_to(effect) if effect.is_harmful else 0.0
		_run_once(application)


## True if the pawn can rest (pawn spec 15.3): nothing in the list to count down, and nothing waiting to be worked out.
func can_rest() -> bool:
	return _entries.is_empty() and not _dirty


# --- Questions and removing ----------------------------------------------------------------------


## True while this over-time effect is on the pawn.
func has_effect(effect: Effect) -> bool:
	return effect != null and _find(effect.get_id()) >= 0


## How many stacks of it the pawn has: 0 if none.
func get_stacks(effect: Effect) -> int:
	var at := _find(effect.get_id()) if effect else -1
	return int(_entries[at + STACKS]) if at >= 0 else 0


## Ticks it has left: 0 if it isn't on the pawn.
func get_ticks_left(effect: Effect) -> int:
	var at := _find(effect.get_id()) if effect else -1
	return int(_entries[at + TICKS_LEFT]) if at >= 0 else 0


## Every active effect, for readouts: [{"effect": Effect or null, "ticks_left", "stacks", "source": Pawn or null}], oldest first.
func get_active_effects() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for at in range(0, _entries.size(), STRIDE):
		out.append({"effect": Effect.find(_entries[at + ID]), "ticks_left": int(_entries[at + TICKS_LEFT]),
				"stacks": int(_entries[at + STACKS]), "source": _source_pawn(_entries[at + SOURCE])})
	return out


## Removes an over-time effect, if it's on the pawn.
func remove_effect(effect: Effect) -> void:
	var at := _find(effect.get_id()) if effect else -1
	if at >= 0:
		_remove_at(at)
		_refresh()
		effect_ended.emit(effect)


## Removes every active effect with this effect tag, or a tag inside it: remove_with_tag(EffectTags.DEBUFF) is a cleanse.
func remove_with_tag(tag: StringName) -> void:
	for entry in get_active_effects():
		var effect: Effect = entry["effect"]
		if effect and effect.has_tag(tag):
			remove_effect(effect)


## Removes everything. The pawn does this when it dies.
func remove_all() -> void:
	var ended: Array[Effect] = []
	for entry in get_active_effects():
		if entry["effect"]:
			ended.append(entry["effect"])
	if not _entries.is_empty():
		_entries = PackedInt64Array()
		_refresh()
	for effect in ended:
		effect_ended.emit(effect)


## This pawn's resistance to an effect (see the top of the file), not capped: 1 or more means immune.
func resistance_to(effect: Effect) -> float:
	if _dirty:
		_refresh()
	var mask := effect.get_tag_mask()
	var total := 0.0
	for pair in _resistance_bits:
		if mask & pair[0] != 0:
			total += pair[1]
	return total


## What held AbilityPriorityParts add to this ability's number now (AbilityPriorityPart.Number). The AbilityManager asks.
func ability_bonus(ability: AbilityBase, number: int) -> int:
	if _dirty:
		_refresh()
	var total := 0
	for pair in _ability_bonuses[number]:
		if ability.category_mask & pair[0] != 0:
			total += pair[1]
	return total


## True if any held AbilityPriorityPart changes ability numbers now. Lets the AbilityManager skip asking.
func has_ability_bonuses() -> bool:
	if _dirty:
		_refresh()
	return not (_ability_bonuses[0].is_empty() and _ability_bonuses[1].is_empty() and _ability_bonuses[2].is_empty())


# --- Internals -----------------------------------------------------------------------------------


# The do-once parts, in order. On the authority only. Stops when the pawn dies, and adds threat for Health taken from a source.
func _run_once(application: EffectApplication) -> void:
	if not pawn.is_authority():
		return
	for part in application.effect.parts:
		if part == null or part.is_held():
			continue
		part.apply_once(application)
		if not pawn.is_dead() and pawn.stat_manager and pawn.stat_manager.has_stat(&"Health") and pawn.get_health() <= 0.0:
			pawn.health_ran_out(application.hit)
		if pawn.is_dead():
			break
	var source := application.source
	if application.damage_dealt > 0.0 and pawn.ai_memory and is_instance_valid(source) and source != pawn:
		pawn.ai_memory.add_threat(source, application.damage_dealt * pawn.ai_memory.threat_per_damage)


# Where this effect's id is in the list (the index of its first number), or -1.
func _find(id: int) -> int:
	for at in range(0, _entries.size(), STRIDE):
		if _entries[at + ID] == id:
			return at
	return -1


func _remove_at(at: int) -> void:
	# GDScript note: a packed array has no "remove several", so the five numbers go one at a time from the same place.
	for i in STRIDE:
		_entries.remove_at(at)
	_dirty = true


# Works out what every held part in the list adds up to, and puts the stats right.
func _refresh() -> void:
	_dirty = false
	var stat_changes := {}
	_ability_bonuses = [[], [], []]
	_resistance_bits = []
	for tag: StringName in resistances:
		_resistance_bits.append([EffectTags.own_bit(tag), resistances[tag]])
	for at in range(0, _entries.size(), STRIDE):
		var effect := Effect.find(_entries[at + ID])
		if effect == null:
			_warn_once("unknown:%d" % _entries[at + ID], "EffectManager: an effect on %s isn't known on this machine (id %d), so its held parts do nothing here. Give an effect made in code an effect_name." % [pawn.name if pawn else "?", _entries[at + ID]])
			continue
		var stacks := int(_entries[at + STACKS])
		for part in effect.parts:
			if part is StatModifierPart:
				var change: Array = stat_changes.get(part.stat, [0.0, 1.0])
				change[0] += part.add * stacks
				change[1] *= pow(part.multiply, stacks)
				stat_changes[part.stat] = change
			elif part is AbilityPriorityPart:
				if part.ability_tag != &"":
					_ability_bonuses[part.number].append([TagRegistry.own_bit(part.ability_tag), part.amount * stacks])
			elif part is ResistancePart:
				if part.tag != &"":
					_resistance_bits.append([EffectTags.own_bit(part.tag), part.amount * stacks])
	_stat_changes = stat_changes
	_apply_stat_changes()


# Every stat a held part changes now, or changed before, set from its base value.
func _apply_stat_changes() -> void:
	if pawn == null or pawn.stat_manager == null:
		return
	for stat_name in _stat_changes:
		_touched_stats[stat_name] = true
	for stat_name in _touched_stats.keys():
		var stat := pawn.stat_manager.get_stat(stat_name)
		if stat == null:
			continue
		var change: Array = _stat_changes.get(stat_name, [0.0, 1.0])
		stat.value = (stat.base_value + change[0]) * change[1]
		if stat.changes_during_play and stat.current > stat.value:
			stat.current = stat.value
		if not _stat_changes.has(stat_name):
			_touched_stats.erase(stat_name) # back to its base, and nothing holds it now


# The number the list keeps for a source: its entity id online (the same on every machine), else its instance id. -1 for none.
func _source_key(source: Pawn) -> int:
	if not is_instance_valid(source):
		return -1
	var entity := source.get_network_entity()
	return entity.entity_id if entity and entity.entity_id >= 0 else source.get_instance_id()


func _source_pawn(key: int) -> Pawn:
	if key < 0:
		return null
	var own_entity := pawn.get_network_entity() if pawn else null
	if own_entity and own_entity.session:
		var entity: NetworkEntity = own_entity.session.get_entity(key)
		return entity.get_parent() as Pawn if entity else null
	var found := instance_from_id(key)
	return found as Pawn if is_instance_valid(found) else null


func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(message)
