# Written by Claude (claude-opus-5-5), 2026-11-24. History: effects/CHANGELOG.md.
## Something an [Effect] does at a moment, such as damage: the base for the entries in [member Effect.effectors] (pawn spec 16.8).
##
## An effector overrides [method fire]. It fires when its effect is applied and, for an over-time effect with a period, at each period;
## on the authority only, after the effect's modifiers have taken hold. One keeps no state while playing: it's shared by every pawn its
## effect lands on.
class_name EffectEffector
extends Resource


## Fires on the pawn the effect landed on. application says who, from whom, how many stacks and what resistance applies, and collects
## results such as the damage dealt.
func fire(_application: EffectApplication) -> void:
	pass
