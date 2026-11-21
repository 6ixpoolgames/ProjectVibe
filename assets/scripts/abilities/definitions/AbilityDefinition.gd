# Written by Claude (claude-opus-5-5), 2026-11-21. History: abilities/CHANGELOG.md.
@tool
## The settings one variant of an ability has, shared by every pawn that uses it, such as "Goblin Swing": a Resource an ability node
## points at (ability spec 3).
##
## Each kind of ability has its own class with its settings added ([MeleeAttackDefinition]); a new one starts with the kind's defaults.
## Variants ([member Definition.based_on]) come from [Definition]. Read-only while playing: every pawn using it shares it. A pawn that
## needs other numbers uses another definition ([method AbilityBase.use_definition]), or gets them from stats and effects.
class_name AbilityDefinition
extends Definition

## The named action that starts it, such as &"jump". Empty: only the manager starts it, as the default locomotion.
@export var trigger_action: StringName = &"":
	set(value):
		trigger_action = value
		_changed(&"trigger_action", value)
## What it is, as a tag such as &"movement.jump". Used for lockouts. Empty: nothing can lock it out.
@export var category: StringName = &"":
	set(value):
		category = value
		_changed(&"category", value)
## More groups it belongs to besides category, such as &"movement.advanced" for a dash. Lockouts, cancels and
## [method AbilityManager.action_for_tag] answer to all of them. They share one 64-bit mask with every other ability tag.
@export var extra_categories: Array[StringName] = []:
	set(value):
		extra_categories = value
		_changed(&"extra_categories", value)
## Which ability a press picks among those on one action: the highest that can start wins, then the first in the tree. Locomotion
## with a held action works the same. Effects can add to it (AbilityPriorityPart, pawn spec 8.11).
@export var priority: int = 0:
	set(value):
		priority = value
		_changed(&"priority", value)
## Which combo positions it can fill: [1] an opener, [2] a second hit, [2, 3] second or third. A follow-up (no 1) starts only while the
## combo window is open; give it a higher priority than the opener so it wins there. Empty: not in combos. Pawn spec 8.20.
@export var combo_positions: Array[int] = []:
	set(value):
		combo_positions = value
		_changed(&"combo_positions", value)
## A random offset, up to plus or minus this, added to priority when a press picks between abilities. 0: none. It comes from the tick's
## own random numbers ([method TickDriver.tick_rng]), so a replay picks the same ability. Locomotion ignores it.
@export var priority_jitter: float = 0.0:
	set(value):
		priority_jitter = value
		_changed(&"priority_jitter", value)
## Seconds. For an action, 0 means it happens at once. For locomotion, 0 means it runs as long as it's wanted.
@export_range(0.0, 60.0, 0.05, "or_greater") var duration: float = 0.0:
	set(value):
		duration = value
		_changed(&"duration", value)
## Seconds after it stops before it can start again.
@export_range(0.0, 60.0, 0.05, "or_greater") var cooldown: float = 0.0:
	set(value):
		cooldown = value
		_changed(&"cooldown", value)
## Categories that can't start, or steer, while this runs, such as &"movement" for an attack that roots the pawn.
@export var locks_out: Array[StringName] = []:
	set(value):
		locks_out = value
		_changed(&"locks_out", value)
## Seconds a press waits if the ability can't start yet, such as jump pressed just before landing. 0: a press is tried once.
@export_range(0.0, 2.0, 0.01, "or_greater") var buffer_window: float = 0.0:
	set(value):
		buffer_window = value
		_changed(&"buffer_window", value)
## How hard it cancels a running ability it conflicts with (pawn spec 8.6): Walk 0, Jump 5, Sprint 10, Parry 10, MeleeAttack 15,
## Knockback 30, Dash 40, Death 1000.
@export var interrupt_priority: int = 0:
	set(value):
		interrupt_priority = value
		_changed(&"interrupt_priority", value)
## While it runs, a conflicting ability with at least this interrupt_priority cancels it; a weaker one is locked out. 100: only Death
## cancels it. MeleeAttack uses 15, so Dash cancels a swing and Sprint doesn't.
@export var interrupt_threshold: int = 100:
	set(value):
		interrupt_threshold = value
		_changed(&"interrupt_threshold", value)
# For invulnerability while it runs, give it an InvulnerabilityInterceptor child (HitInterceptor); Dash makes one by default.
## Categories that can always cancel it while it runs, whatever the interrupt numbers say, such as &"movement.jump". A category covers
## its children, as in locks_out.
@export var cancelled_by: Array[StringName] = []:
	set(value):
		cancelled_by = value
		_changed(&"cancelled_by", value)
## On: locomotion (Walk, Sprint) doesn't run at all while this does, so it neither steers nor slows the pawn (Dash). Off: a locked-out
## locomotion still slows the pawn to a stop, as an attack that roots the pawn wants.
@export var pauses_locomotion: bool = false:
	set(value):
		pauses_locomotion = value
		_changed(&"pauses_locomotion", value)
## On: while it runs the pawn moves by physics ([code]move_and_slide[/code]), not the CrowdMover, so fast or forced moves such as Dash
## and Knockback collide properly. Pawn spec 8.22.
@export var needs_full_movement: bool = false:
	set(value):
		needs_full_movement = value
		_changed(&"needs_full_movement", value)
## For a stepped ability: when each step runs (ability spec 6.2), as entries in ticks from its start. Empty: its kind's default (a
## swing's windup, sweep and recovery), or its steps one after another.
@export var step_timeline: Array[TimelineEntry] = []:
	set(value):
		step_timeline = value
		_changed(&"step_timeline", value)
## For a stepped ability, the longest it can run, in ticks at 60 a second. It ends when no step runs, or at this. Ignored without steps.
@export_range(1, 6000, 1, "or_greater") var max_steps_ticks: int = 600:
	set(value):
		max_steps_ticks = value
		_changed(&"max_steps_ticks", value)
