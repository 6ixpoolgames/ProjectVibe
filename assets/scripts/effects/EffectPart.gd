# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## One thing an [Effect] does: the base for the parts in an Effect's parts list.
##
## Do-once parts override [method apply_once] and run on the authority only. Held parts override [method is_held] (return true) and
## [method add_held], and work on every machine. A part keeps no state while playing: one is shared by every pawn its effect lands on.
## Design: pawn spec 8.11.
class_name EffectPart
extends Resource


## True for a part that holds while its effect lasts, instead of running once.
func is_held() -> bool:
	return false


## A held part adds what it does to the pawn's totals, stacks times. Called whenever the pawn's list of effects changes, on every
## machine. Override it in a held part; the base does nothing.
func add_held(_totals: EffectHeldTotals, _stacks: int) -> void:
	pass


## Runs a do-once part on the pawn the effect landed on. application says who, from whom, how many stacks and what resistance
## applies, and collects results such as the damage dealt.
func apply_once(_application: EffectApplication) -> void:
	pass
