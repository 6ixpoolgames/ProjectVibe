# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings one variant of an AI behaviour has, shared by every pawn that uses it, such as "Goblin Chase": a Resource a behaviour
## node points at (pawn spec 16.3).
##
## Each kind of behaviour has its own class with its settings added ([AIChaseDefinition]); a new one starts with the kind's defaults.
## Variants ([member Definition.based_on]) come from [Definition]. Read-only while playing: every pawn using it shares it. A pawn that
## needs other numbers uses another definition ([method AIBehaviourBase.use_definition]) or a behaviour modifier.
class_name AIBehaviourDefinition
extends Definition

## What it is, as tags such as &"ai.stance.melee": what behaviour modifiers pick behaviours by ([member AIBehaviourModifier.applies_to]).
@export var tags: Array[StringName] = []:
	set(value):
		tags = value
		_changed(&"tags", value)
## When it may run: a query over the pawn's owned tags, such as any of ai.state.combat (the AI's state is a tag), or none of
## status.has_ammo. While it fails, the behaviour can't be chosen, and a running one is replaced at the next AI step. Empty: always.
@export var tag_requirements: TagQuery:
	set(value):
		tag_requirements = value
		_changed(&"tag_requirements", value)
## The highest its score can be. Lets the manager skip it without running its code when it can't win.
@export var max_score := 0.5:
	set(value):
		max_score = value
		_changed(&"max_score", value)
## Optional: the lowest its score can be. Left at -inf it can't help skip others, but it's never wrong.
@export var min_score := -INF:
	set(value):
		min_score = value
		_changed(&"min_score", value)
## Skipped while the AI has no current target.
@export var needs_target := false:
	set(value):
		needs_target = value
		_changed(&"needs_target", value)
## A named action it presses, such as &"primary". Skipped while that action couldn't start.
@export var presses_action: StringName = &"":
	set(value):
		presses_action = value
		_changed(&"presses_action", value)
## More conditions it needs, on top of its kind's own ([method AIBehaviourBase.own_conditions]). All must pass. Made in the inspector:
## compare an input with a number, a random chance, or "any of".
@export var conditions: Array[AICondition] = []:
	set(value):
		conditions = value
		_changed(&"conditions", value)
## Optional: inputs that scale its score between min_score (or 0) and max_score, multiplied together. Empty: always max_score.
@export var score_curves: Array[AIScoreCurve] = []:
	set(value):
		score_curves = value
		_changed(&"score_curves", value)
## Ticks after it ends before it can be chosen again. A hard rule, checked before any scoring.
@export_range(0, 36000, 1, "or_greater") var cooldown_ticks := 0:
	set(value):
		cooldown_ticks = value
		_changed(&"cooldown_ticks", value)
## Once chosen, ordinary decisions can't replace it for this many ticks. State changes still can, if strong enough. Behaviour
## modifiers can change it, as they can cooldown_ticks, interrupt_threshold and score_jitter.
@export_range(0, 36000, 1, "or_greater") var min_run_ticks := 0:
	set(value):
		min_run_ticks = value
		_changed(&"min_run_ticks", value)
## While it runs, only events of this priority or higher can replace it: 0 for an ordinary decision, a state's priority for a state
## change. 0: anything can.
@export var interrupt_threshold := 0:
	set(value):
		interrupt_threshold = value
		_changed(&"interrupt_threshold", value)
## Runs until it returns SUCCEEDED or FAILED, whatever happens, even if its state no longer allows it. Use sparingly.
@export var cannot_be_interrupted := false:
	set(value):
		cannot_be_interrupted = value
		_changed(&"cannot_be_interrupted", value)
## ± random offset on its score at each decision, for variety. -1: the manager's default_score_jitter.
@export var score_jitter := -1.0:
	set(value):
		score_jitter = value
		_changed(&"score_jitter", value)
## While it runs, its tick() is called every this many ticks, and sooner when a wake-up it asked for happens (the longest it sleeps).
## 1: every tick.
@export_range(1, 600, 1, "or_greater") var tick_interval_ticks := 1:
	set(value):
		tick_interval_ticks = value
		_changed(&"tick_interval_ticks", value)
## A modifier it gives itself as it starts, such as a score bonus that keeps it chosen a while. Empty applies_to: only this behaviour.
## With no duration it lasts while the behaviour runs; with one, its duration from the start. Starting again replaces it.
@export var modifier_on_start: AIBehaviourModifier:
	set(value):
		modifier_on_start = value
		_changed(&"modifier_on_start", value)
## A modifier it gives itself as it ends, such as -0.3 to its score for 15 s so something else gets a turn. Empty applies_to: only this
## behaviour. With no duration it lasts until the behaviour starts again; with one, its duration. Ending again replaces it.
@export var modifier_on_end: AIBehaviourModifier:
	set(value):
		modifier_on_end = value
		_changed(&"modifier_on_end", value)
