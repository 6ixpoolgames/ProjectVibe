# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## One thing an [Effect] does: the base for the parts in an Effect's parts list.
##
## The inspector offers the parts list as a dropdown of these classes. Pawn spec 8.11.
## [br]
## Two kinds:
## [br]- [b]Do once[/b]: runs when an effect is applied (an instant one), or when an over-time one is first applied and then every
##   period. Override [method apply_once]. On the authority only (the EffectManager calls it), so it may change Health and start
##   abilities.
## [br]- [b]Held[/b]: holds while an over-time effect lasts, and stops when it ends. Override [method is_held] to return true, and
##   [method add_held] to add what it does to the pawn's totals ([EffectHeldTotals]); the EffectManager asks whenever its active list
##   changes. Works on every machine.
## [br]
## A new kind of part: extend this (or a part like it), give it @export settings, and do one of the two above. Parts keep no state
## of their own while playing: one part is shared by every pawn the effect lands on, so anything that changes lives on the pawn.
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
