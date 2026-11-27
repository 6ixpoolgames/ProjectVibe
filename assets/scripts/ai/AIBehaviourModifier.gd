# Written by Claude (claude-opus-5-5), 2026-11-23. History: ai/CHANGELOG.md.
@tool
## A change to some behaviours while it lasts: "Charge!" raising melee, fear lowering fighting, confusion's extra jitter, a block.
##
## The generic modifier (pawn spec 16.5, 16.9) aimed at behaviours by their tags: it changes one of their numbers ([member number]),
## multiplying, then adding, or overriding it (the last added wins). A designer-made [Definition] (with variants), given to a pawn's
## behaviour manager by whatever causes it and kept under that source:
## [codeblock]
## pawn.ai.behaviour_manager.add_modifier(charge_shout, self)
## pawn.ai.behaviour_manager.remove_modifiers(self)
## [/codeblock]
## A behaviour can also apply one to itself always, as it starts or as it ends ([member AIBehaviourDefinition.modifier_on_start]).
## [br][br]
## An optional [member curve] eases it in or out: how strongly it applies, from -1 to 1, over the time since it was added or over an
## input. Strength s scales the change: a multiply m becomes [code]1 + (m - 1) × s[/code] (stopping at ×0 when reversed) and an add a
## becomes [code]a × s[/code]; at -1 the change is reversed. A Chase that's hard to interrupt at first, then easier:
## [codeblock]
## number INTERRUPT_THRESHOLD, add 40, curve from 1 at x 0 down to 0 at x 120 (ticks since it was added, at 60 a second)
## [/codeblock]
## Only on the server, where the AI runs. Both deciders work it out the same way (the C++ decider gets the baked curve).
class_name AIBehaviourModifier
extends Definition

## Which of a behaviour's numbers it changes.
enum Number {
	SCORE, ## its score ([member AIBehaviourDefinition.base_score], or what its score() gives)
	SCORE_JITTER, ## the ± random offset on its score (AIBehaviourDefinition.score_jitter, or the manager's default)
	INTERRUPT_THRESHOLD, ## how strong an event must be to replace it while it runs
	COOLDOWN_TICKS, ## ticks after it ends before it can be chosen again, at 60 a second
	MIN_RUN_TICKS, ## ticks an ordinary decision can't replace it once chosen, at 60 a second
}

## How many points a baked curve has, over its domain ([method strength_table]). The C++ decider reads the same table.
const CURVE_POINTS := 65

## Which behaviours it changes: a query over each behaviour's own tags ([member AIBehaviourDefinition.tags]), such as any of
## ai.stance.melee. Empty: every behaviour, or, given by a behaviour to itself, only that behaviour.
@export var applies_to: TagQuery:
	set(value):
		applies_to = value
		_changed(&"applies_to", value)
## Which number it changes.
@export var number := Number.SCORE:
	set(value):
		number = value
		_changed(&"number", value)
## The number is multiplied by this, before the adds. 1: nothing. Multiplies from several modifiers combine.
@export var multiply := 1.0:
	set(value):
		multiply = value
		_changed(&"multiply", value)
## Added after the multiplies. Negative takes away: -30 drops a behaviour that scores 60 to 30.
@export var add := 0.0:
	set(value):
		add = value
		_changed(&"add", value)
## On: the number takes [member override_value], whatever the others do (the last one added wins). A berserk state's threshold.
## A curve doesn't scale it.
@export var overrides := false:
	set(value):
		overrides = value
		_changed(&"overrides", value)
## With [member overrides], the number's value.
@export var override_value := 0.0:
	set(value):
		override_value = value
		_changed(&"override_value", value)
## On: the behaviours it applies to can't be chosen while it counts, and a running one is replaced; its number change is ignored.
## A curve doesn't scale it.
@export var blocks := false:
	set(value):
		blocks = value
		_changed(&"blocks", value)
## Optional: how strongly it applies (y, from -1 to 1) over x, which is [member curve_input] or, with none, the ticks since it was
## added (at 60 a second). Set the curve's domain (min_domain, max_domain) to the x range it spans; beyond it the end values hold.
## A time curve settles once past its domain, and then costs nothing. Empty: full strength (1) always.
@export var curve: Curve:
	set(value):
		curve = value
		_table = PackedFloat64Array()
		_changed(&"curve", value)
## The input the curve's x reads, such as target_distance (see [AIInputs]); an input in ticks is read at 60 a second. Empty: the
## ticks since the modifier was added.
@export_custom(PROPERTY_HINT_ENUM_SUGGESTION, AICondition.INPUT_SUGGESTIONS) var curve_input := "":
	set(value):
		curve_input = value
		_changed(&"curve_input", value)
## How long it lasts once added, in ticks at 60 a second; the manager keeps the tick it ends. 0: until its source removes it.
@export_range(0, 36000, 1, "or_greater") var duration_ticks := 0:
	set(value):
		duration_ticks = value
		_changed(&"duration_ticks", value)
## It counts only while the pawn's owned tags pass this, such as none of status.has_ammo. Empty: always.
@export var ongoing_requirements: TagQuery:
	set(value):
		ongoing_requirements = value
		_changed(&"ongoing_requirements", value)
## Tags the pawn owns while it's added, so other queries can see it (an "ai.stance.melee" order, say).
@export var granted_tags: Array[StringName] = []:
	set(value):
		granted_tags = value
		_changed(&"granted_tags", value)
## On: adding or removing it asks for a decision at once. Off by default: hundreds of pawns deciding on one tick is a spike.
@export var wakes_decision := false:
	set(value):
		wakes_decision = value
		_changed(&"wakes_decision", value)

var _table := PackedFloat64Array()


## True if it applies to this behaviour. only: the behaviour that gave it to itself (null: none), which an empty applies_to means.
func applies_to_behaviour(behaviour: AIBehaviourBase, only: AIBehaviourBase = null) -> bool:
	if applies_to == null or applies_to.is_empty():
		return only == null or only == behaviour
	return applies_to.matches_words(behaviour.tag_words())


## True if it counts for owned tags given as words (its ongoing requirements pass).
func counts_for(owned_words: PackedInt64Array) -> bool:
	return ongoing_requirements == null or ongoing_requirements.matches_words(owned_words)


## True if a curve scales it: it has one, and it's a multiply or an add (not an override or a block).
func is_curved() -> bool:
	return curve != null and not overrides and not blocks


## Its curve baked into [constant CURVE_POINTS] strengths, evenly over the curve's domain, each kept within -1 to 1. Worked out once:
## a curve edited during play isn't seen. Empty with no curve.
func strength_table() -> PackedFloat64Array:
	if curve == null:
		return PackedFloat64Array()
	if _table.is_empty() or Engine.is_editor_hint():
		var low := curve.min_domain
		var high := curve.max_domain
		_table.resize(CURVE_POINTS)
		for i in CURVE_POINTS:
			var x := low + (high - low) * float(i) / float(CURVE_POINTS - 1)
			_table[i] = clampf(curve.sample(x), -1.0, 1.0)
	return _table


## The strength at x, from the baked table ([method strength_table]): a straight line between its points, the end values beyond
## the domain. Twin of the C++ decider's: the same arithmetic.
static func strength_in(table: PackedFloat64Array, low: float, high: float, x: float) -> float:
	var last := table.size() - 1
	if x <= low or high <= low:
		return table[0]
	if x >= high:
		return table[last]
	var place := (x - low) / (high - low) * float(last)
	var i := mini(int(place), last - 1)
	var part := place - float(i)
	return table[i] + (table[i + 1] - table[i]) * part


## A multiply with strength s: [code]1 + (m - 1) × s[/code], never below 0 while reversed (s below 0). Twin of the C++ decider's.
static func multiply_at(m: float, s: float) -> float:
	var factor := 1.0 + (m - 1.0) * s
	return 0.0 if s < 0.0 and factor < 0.0 else factor
