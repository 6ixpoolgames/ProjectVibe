# Written by Claude (claude-opus-5-5), 2026-11-24. History: status/CHANGELOG.md.
## A pawn's status: its stats and the effects on it, in one component (pawn spec 16.8).
##
## Stats are [Stat] child nodes, found by name; a missing stat is never an error ([method get_value] gives the fallback). Effects
## ([Effect]) are applied with [method apply_effect]: instant ones run at once; over-time ones go in a rolled-back active list that
## keeps the tick each ends and the tick of its next period (deadlines: nothing counts down), and all end when the pawn dies. Do-once
## parts run on the authority only; modifiers work on every machine. Every change to a stat's current value goes through
## [method change_current], which sends the stat's threshold events through the pawn ([method Pawn.send_event]) when a change crosses
## one: Health at 0 sends [code]event.health.depleted[/code]. Health taken by an effect sends [code]event.damage.taken[/code] with its source.
## [codeblock]
## pawn.status_manager.get_value(&"MoveSpeed", 5.0)         # a stat's value, or the fallback without it
## pawn.status_manager.change_current(&"Health", -20, who)  # the server: kept between 0 and its max; sends threshold events
## pawn.status_manager.apply_effect(effect, source)         # source: who applied it (memory, lifesteal), or null
## pawn.status_manager.remove_with_tag(Tags.EFFECT.DEBUFF)  # a cleanse
## [/codeblock]
class_name StatusManager
extends Node

## Sent when an effect is applied, on every machine that applies it (effectors only ran if this is the authority).
signal effect_applied(effect: Effect, application: EffectApplication)
## Sent when an over-time effect ends or is removed.
signal effect_ended(effect: Effect)

## The name of the Health stat. A pawn without a stat of this name can't be hurt or die from damage.
const HEALTH := &"Health"
## The name of the Detectability stat: how easy the pawn is for AI to see (1 normal, 0 invisible). [method detectability_of] reads
## it, and it's copied into the pawn table for the sensing job ([member Stat.table_column]).
const DETECTABILITY := &"Detectability"

## Numbers per entry in [member active_effects]; ID, ENDS_AT, NEXT_PERIOD_AT, STACKS and SOURCE are their positions in an entry.
const STRIDE := 5
const ID := 0
const ENDS_AT := 1 ## the tick it ends
const NEXT_PERIOD_AT := 2 ## the tick its effectors run again; -1 without a period
const STACKS := 3
const SOURCE := 4
const _NO_DEADLINE := 0x7FFFFFFFFFFFFFFF
## What ENDS_AT holds for an effect that lasts until removed ([member Effect.lasts_until_removed]).
const UNTIL_REMOVED := _NO_DEADLINE

## This pawn's resistances by effect tag: 0.25 takes a quarter off harmful effects, 1 or more ignores them, negative is a weakness.
## [br]A tag counts for every effect inside it, and they add up (0.2 effect.damage.elemental + 0.3 effect.damage.elemental.fire = 0.5 against fire).
@export var resistances: Dictionary[StringName, float] = {}
## The most over-time effects this pawn can have at once. A new one past this is refused.
@export_range(1, 64, 1, "or_greater") var max_active_effects := 16

# The getter and setter make this a window onto _entries: the setter notices a rollback loading a list. Running periods changes _entries
# in place, skipping the setter, so the modifiers are only worked out again when the list really changes.
## The active list, five numbers per effect (see [constant STRIDE]); rolled back and sent in snapshots. Read it with [method get_active_effects].
var active_effects: PackedInt64Array:
	get:
		return _entries
	set(value):
		_entries = value
		_dirty = true
		_set_owned_tags() # at once, unlike the rest: a client never runs the effects of pawns it only draws

## The pawn it belongs to (its parent), or null outside a pawn.
var pawn: Pawn = null
## Goes up by one whenever a stat's value changes, or a stat is added or removed (not when a current value such as Health changes).
## An ability that keeps stat values reads them again only when this has changed (pawn spec 15.2).
var version := 1

var _stats := {} # StringName -> Stat
var _entries := PackedInt64Array()
var _dirty := true # the list changed: what the modifiers add up to is worked out again before it's next used
var _soonest := _NO_DEADLINE # the soonest end or period in the list, worked out when it changes
# What the modifiers add up to, worked out from the list (see _refresh):
var _stat_changes := {} # stat name -> [added, multiplied]
var _touched_stats := {} # stat names the modifiers have changed, so they go back to their base when the parts end
var _ability_bonuses: Array = [[], [], []] # per AbilityModifier.Number: [ability tag bit, amount] pairs
var _resistance_bits: Array = [] # [effect tag bit, amount] pairs, from resistances and held ResistanceModifiers
var _parries: Array[ParryModifier] = [] # held ParryModifiers, for the hit ability
var _warned := {}


## How easy this pawn is for AI to see: its Detectability stat's value, 1 without one (pawn spec 10.4). Effects change it through the
## stat; game rules for stealth belong in a GameMode module.
static func detectability_of(of_pawn: Node) -> float:
	var manager: StatusManager = of_pawn.get(&"status_manager") if of_pawn else null
	var stat: Stat = manager.get_stat(DETECTABILITY) if manager else null
	return stat.value if stat else 1.0


## Sets this pawn's Detectability stat's base value (what effects build on). Does nothing for a pawn without the stat.
# REFACTOR: only tests call it; a test helper in tests/ would keep it out of the shipping class (status/CHANGELOG.md).
static func set_detectability(of_pawn: Node, value: float) -> void:
	var manager: StatusManager = of_pawn.get(&"status_manager") if of_pawn else null
	var stat: Stat = manager.get_stat(DETECTABILITY) if manager else null
	if stat:
		stat.base_value = value


func _init() -> void:
	set_process(false)
	set_physics_process(false)
	# These fire for children added at any time, including the scene's own as they enter the tree.
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	# It tells its pawn it's here, before any part's _ready; the first StatusManager a pawn has is the one it uses.
	if pawn and not is_instance_valid(pawn.status_manager):
		pawn.status_manager = self
	if pawn == null:
		push_warning("StatusManager: its parent isn't a Pawn, so its effects do nothing.")


# Stats that change during play start full, and their current values and the active list roll back. Runs before the first tick.
func _ready() -> void:
	var entries: Array[String] = []
	var recorded: Array[Stat] = []
	for stat_name: StringName in _stats:
		var stat: Stat = _stats[stat_name]
		if stat.changes_during_play:
			stat.current = stat.value
			if pawn:
				entries.append("%s:current pushed" % String(pawn.get_path_to(stat)))
				recorded.append(stat)
	if pawn == null:
		return
	# Dying ends every effect on it (pawn spec 8.11).
	var abilities := pawn.ability_manager
	if abilities:
		abilities.died.connect(func(_pawn: Pawn, _hit: HitInfo) -> void: remove_all())
	entries.append("%s:active_effects" % String(pawn.get_path_to(self)))
	for child in pawn.get_children():
		if child is TickStateComponent:
			child.add_state_properties(entries)
			# Each stat pushes its current value when it changes, instead of the store reading it every tick.
			for stat in recorded:
				stat._tick_state = child
				stat._state_key = "%s:current" % String(pawn.get_path_to(stat))
			break


# --- Stats ---------------------------------------------------------------------------------------


## How much Health the pawn has now, or 0 without a Health stat.
func get_health() -> float:
	return get_current(HEALTH, 0.0)


## How much a stat that changes during play has now, or the fallback if there's no such stat.
func get_current(stat_name: StringName, fallback := 0.0) -> float:
	var stat: Stat = _stats.get(stat_name)
	return stat.current if stat and stat.changes_during_play else fallback


## Adds to a stat that changes during play (negative takes away), kept between 0 and its value. Returns the new amount, or 0 if there's
## no such stat. A change that crosses one of the stat's [member Stat.thresholds] sends that threshold's event at once, through the
## pawn, with [param source] as its instigator and [param cause] (a hit, say) as its object. Only the server should change it: clients
## get it in snapshots, and a value a snapshot or rollback restores sends nothing.
func change_current(stat_name: StringName, amount: float, source: Node = null, cause: Object = null) -> float:
	var stat: Stat = _stats.get(stat_name)
	if stat == null or not stat.changes_during_play:
		return 0.0
	var before := stat.current
	stat.current = clampf(before + amount, 0.0, stat.value)
	if stat.current != before and not stat.thresholds.is_empty():
		_send_crossed(stat, before, source, cause)
	return stat.current


## Fills a stat that changes during play to its value (a revive, a level start). Sends no threshold events.
func fill_current(stat_name: StringName) -> void:
	var stat: Stat = _stats.get(stat_name)
	if stat and stat.changes_during_play:
		stat.current = stat.value


## The stat's value right now, or fallback if this pawn has no such stat.
func get_value(stat_name: StringName, fallback := 0.0) -> float:
	var stat: Stat = _stats.get(stat_name)
	return stat.value if stat else fallback


## The Stat node, or null if there's none with that name.
func get_stat(stat_name: StringName) -> Stat:
	return _stats.get(stat_name)


## True if this pawn has a stat with that name.
func has_stat(stat_name: StringName) -> bool:
	return _stats.has(stat_name)


## Every stat's name.
func get_stat_names() -> Array[StringName]:
	var names: Array[StringName] = []
	for stat_name: StringName in _stats:
		names.append(stat_name)
	return names


# Each threshold the change from before to the stat's current value crossed downward, in list order.
func _send_crossed(stat: Stat, before: float, source: Node, cause: Object) -> void:
	if pawn == null:
		return
	for threshold in stat.thresholds:
		if threshold == null or threshold.event == &"":
			continue
		var level := threshold.level_for(stat.value)
		if before > level and stat.current <= level:
			var data := GameplayEventData.new()
			data.instigator = source
			data.magnitude = stat.current
			data.optional_object = cause
			pawn.send_event(threshold.event, data)


func _on_child_entered(node: Node) -> void:
	if node is Stat:
		_stats[StringName(node.name)] = node
		version += 1


func _on_child_exiting(node: Node) -> void:
	if node is Stat and _stats.get(StringName(node.name)) == node:
		_stats.erase(StringName(node.name))
		version += 1


# --- Applying effects ------------------------------------------------------------------------------


## Applies an effect to this pawn. source is who applied it, or null; source_ability and hit are handed to its parts. Returns false if
## refused: dead, invulnerable, immune, the list full, or IGNORE stacking.
func apply_effect(effect: Effect, source: Pawn = null, source_ability: AbilityBase = null, hit: HitInfo = null) -> bool:
	if pawn:
		pawn.mark_state_changed() # it may land between the pawn's own runs, so the state store reads it this tick
	if effect == null or pawn == null or pawn.is_dead():
		return false
	var resistance := 0.0
	if effect.is_harmful:
		if _is_invulnerable():
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
		if effect.has_modifiers():
			_warn_once("held:" + effect.describe(), "StatusManager: '%s' is instant, so its modifiers do nothing. Give it a duration." % effect.describe())
		effect_applied.emit(effect, application)
		_run_once(application)
		return true
	effect.register()
	var now: int = TickDriver.tick
	var first_time := false
	var at := _find(effect.get_id())
	if at >= 0:
		match effect.stacking:
			Effect.Stacking.IGNORE:
				return false
			Effect.Stacking.ADD_STACK:
				_entries[at + STACKS] = mini(_entries[at + STACKS] + 1, effect.max_stacks)
		_entries[at + ENDS_AT] = _ends_at(effect, now)
		_entries[at + SOURCE] = _source_key(source)
	else:
		if _entries.size() >= max_active_effects * STRIDE: # a multiply, not an integer division, which the editor warns about
			_warn_once("full", "StatusManager: %s already has %d effects on it (max_active_effects), so '%s' was refused." % [pawn.name, max_active_effects, effect.describe()])
			return false
		var period := TickDriver.ticks_at_rate(effect.period_ticks)
		_entries.append_array([effect.get_id(), _ends_at(effect, now),
				now + period if period > 0 else -1, 1, _source_key(source)])
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


## Called by the AbilityManager when a hit lands, on the authority: the hit's effects, from its attacker. Fills in
## hit.damage_dealt.
func take_hit(hit: HitInfo) -> void:
	var before := get_health()
	apply_effects(hit.effects, hit.attacker, hit.ability, hit)
	hit.damage_dealt = maxf(before - get_health(), 0.0)


# --- Each tick -----------------------------------------------------------------------------------


## The pawn calls this once per tick, before its abilities run, while the list has something in it: runs the periods that came due
## and ends the effects whose time is up. Nothing is done between deadlines.
func tick_effects() -> void:
	if _dirty:
		_refresh() # a rollback loaded the list, perhaps an empty one, since the last tick
	if _entries.is_empty():
		return
	var now: int = TickDriver.tick
	if now < _soonest:
		return
	var due: Array = [] # [effect, stacks, source key] whose period came round, run once the list is up to date
	var ended: Array[Effect] = []
	var at := _entries.size() - STRIDE
	while at >= 0: # from the end, so removing one doesn't move the ones still to come
		var effect := Effect.find(_entries[at + ID])
		var ends: int = _entries[at + ENDS_AT]
		# Periods first, for the ticks it was still running: the tick it ends on counts for nothing. A pawn running every Nth tick
		# gets every period that fell due since its last run.
		if effect and effect.period_ticks > 0:
			var period := maxi(TickDriver.ticks_at_rate(effect.period_ticks), 1)
			var last_counted := mini(now, ends - 1)
			while _entries[at + NEXT_PERIOD_AT] >= 0 and _entries[at + NEXT_PERIOD_AT] <= last_counted:
				_entries[at + NEXT_PERIOD_AT] += period
				due.append([effect, int(_entries[at + STACKS]), _entries[at + SOURCE]])
		if now >= ends:
			_remove_at(at)
			if effect:
				ended.append(effect)
		at -= STRIDE
	if not ended.is_empty():
		_refresh() # what ended stops holding before this tick's abilities run
	else:
		_soonest = _soonest_deadline()
	for effect in ended:
		effect_ended.emit(effect)
	if not pawn.is_authority():
		return # effectors are the authority's
	due.reverse() # in list order, oldest first
	for entry in due:
		if pawn.is_dead():
			return
		var effect: Effect = entry[0]
		if effect.is_harmful and _is_invulnerable():
			continue # a dash dodges a poison's tick too
		var application := EffectApplication.new()
		application.effect = effect
		application.target = pawn
		application.source = _source_pawn(entry[2])
		application.stacks = entry[1]
		application.resistance = resistance_to(effect) if effect.is_harmful else 0.0
		_run_once(application)


## True if the pawn can sleep (pawn spec 15.3): no effects, and nothing waiting to be worked out.
func can_sleep() -> bool:
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
	return maxi(int(_entries[at + ENDS_AT]) - TickDriver.tick, 0) if at >= 0 else 0


## Every active effect, for readouts: [{"effect": Effect or null, "ends_at", "ticks_left", "stacks", "source": Pawn or null}], oldest first.
func get_active_effects() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var now: int = TickDriver.tick
	for at in range(0, _entries.size(), STRIDE):
		out.append({"effect": Effect.find(_entries[at + ID]), "ends_at": int(_entries[at + ENDS_AT]),
				"ticks_left": maxi(int(_entries[at + ENDS_AT]) - now, 0), "stacks": int(_entries[at + STACKS]),
				"source": _source_pawn(_entries[at + SOURCE])})
	return out


## Removes an over-time effect, if it's on the pawn.
func remove_effect(effect: Effect) -> void:
	var at := _find(effect.get_id()) if effect else -1
	if at >= 0:
		_remove_at(at)
		_refresh()
		effect_ended.emit(effect)


## Removes every active effect with this effect tag, or a tag inside it: remove_with_tag(Tags.EFFECT.DEBUFF) is a cleanse.
func remove_with_tag(tag: StringName) -> void:
	for entry in get_active_effects():
		var effect: Effect = entry["effect"]
		if effect and effect.has_tag(tag):
			remove_effect(effect)


## Removes everything. Done when the pawn dies (it listens for the AbilityManager's died).
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


## This pawn's resistance to an effect (see [member resistances]), not capped: 1 or more means immune.
func resistance_to(effect: Effect) -> float:
	if _dirty:
		_refresh()
	var mask := effect.get_tag_mask()
	var total := 0.0
	for pair in _resistance_bits:
		if mask & pair[0] != 0:
			total += pair[1]
	return total


## What held AbilityModifiers add to this ability's number now (AbilityModifier.Number). The AbilityManager asks.
func ability_bonus(ability: AbilityBase, number: int) -> int:
	if _dirty:
		_refresh()
	var total := 0
	for pair in _ability_bonuses[number]:
		if ability.category_mask & pair[0] != 0:
			total += pair[1]
	return total


## The parries held now ([ParryModifier]), for the hit ability to ask. Don't change the list.
func get_parries() -> Array[ParryModifier]:
	if _dirty:
		_refresh()
	return _parries


## True if any held AbilityModifier changes ability numbers now. Lets the AbilityManager skip asking.
func has_ability_bonuses() -> bool:
	if _dirty:
		_refresh()
	return not (_ability_bonuses[0].is_empty() and _ability_bonuses[1].is_empty() and _ability_bonuses[2].is_empty())


# --- Internals -----------------------------------------------------------------------------------


# The effectors, in order. On the authority only. Stops when the pawn dies (Health crossing 0 sends event.health.depleted, which
# starts Death). Health taken goes out as event.damage.taken, with its source, once the parts are done.
func _run_once(application: EffectApplication) -> void:
	if not pawn.is_authority():
		return
	for effector in application.effect.effectors:
		if effector == null:
			continue
		effector.fire(application)
		if pawn.is_dead():
			break
	if application.damage_dealt > 0.0:
		var data := GameplayEventData.new()
		data.instigator = application.source
		data.magnitude = application.damage_dealt
		data.optional_object = application.hit
		pawn.send_event(Tags.EVENT.DAMAGE_TAKEN, data)


# The tick an effect applied now ends: never, for one that lasts until removed.
func _ends_at(effect: Effect, now: int) -> int:
	return UNTIL_REMOVED if effect.lasts_until_removed else now + TickDriver.ticks_at_rate(effect.duration_ticks)


# The pawn owns status.invulnerable (a dash's first ticks): harmful effects are refused, and their periods skipped.
func _is_invulnerable() -> bool:
	return pawn.owned_tags != null and pawn.owned_tags.has(Tags.STATUS.INVULNERABLE)


# Where this effect's id is in the list (the index of its first number), or -1.
func _find(id: int) -> int:
	for at in range(0, _entries.size(), STRIDE):
		if _entries[at + ID] == id:
			return at
	return -1


func _remove_at(at: int) -> void:
	for i in STRIDE:
		_entries.remove_at(at)
	_dirty = true


# The soonest end or period still ahead in the list.
func _soonest_deadline() -> int:
	var soonest := _NO_DEADLINE
	for at in range(0, _entries.size(), STRIDE):
		soonest = mini(soonest, _entries[at + ENDS_AT])
		if _entries[at + NEXT_PERIOD_AT] >= 0:
			soonest = mini(soonest, _entries[at + NEXT_PERIOD_AT])
	return soonest


# Works out what every held part in the list adds up to, and puts the stats right.
func _refresh() -> void:
	_dirty = false
	_soonest = _soonest_deadline()
	# Each modifier adds itself to the totals (EffectModifier.add_held), so a new kind of modifier needs no change here.
	var totals := ModifierTotals.new()
	for tag: StringName in resistances:
		totals.resistance_bits.append([TagRegistry.own_bit(tag), resistances[tag]])
	for at in range(0, _entries.size(), STRIDE):
		var effect := Effect.find(_entries[at + ID])
		if effect == null:
			_warn_once("unknown:%d" % _entries[at + ID], "StatusManager: an effect on %s isn't known on this machine (id %d), so its modifiers do nothing here. Give an effect made in code an effect_name." % [String(pawn.name) if pawn else "?", _entries[at + ID]]) # String(): both sides of the if must be text
			continue
		var stacks := int(_entries[at + STACKS])
		for modifier in effect.modifiers:
			if modifier:
				modifier.add_held(totals, stacks)
	_ability_bonuses = totals.ability_bonuses
	if pawn and pawn.ability_manager:
		pawn.ability_manager.readiness_changed() # priority boosts can change what may start (AIInputs.action_ready)
	_resistance_bits = totals.resistance_bits
	_parries = totals.parries
	_stat_changes = totals.stat_changes
	_apply_stat_changes()
	_set_owned_tags()


# The pawn owns every active effect's tags and granted tags, once per effect whatever its stacks (tag spec 3).
func _set_owned_tags() -> void:
	if pawn == null or pawn.owned_tags == null:
		return
	var tags: Array[StringName] = []
	for at in range(0, _entries.size(), STRIDE):
		var effect := Effect.find(_entries[at + ID])
		if effect:
			tags.append_array(effect.tags)
			tags.append_array(effect.granted_tags)
	pawn.owned_tags.set_source(self, tags)


# Every stat a held part changes now, or changed before, set from its base value.
func _apply_stat_changes() -> void:
	for stat_name in _stat_changes:
		_touched_stats[stat_name] = true
	for stat_name in _touched_stats.keys():
		var stat := get_stat(stat_name)
		if stat == null:
			continue
		var change: Array = _stat_changes.get(stat_name, [0.0, 1.0, false, 0.0])
		stat.set_modifiers(change[0], change[1], change[2], change[3]) # the stat works its value out, and keeps it through a new base_value
		if stat.changes_during_play and stat.current > stat.value:
			stat.current = stat.value # a lower max takes the current down with it, without events
		if not _stat_changes.has(stat_name):
			_touched_stats.erase(stat_name) # back to its base, and nothing holds it now


# What the list keeps for a source: its entity id online (the same on every machine), else its instance id. -1: none.
# REFACTOR: offline the source is kept by instance id, not its entity number, because nothing finds an entity by its number yet; the
# entity registry (pawn spec 16.10, step 9) will.
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
