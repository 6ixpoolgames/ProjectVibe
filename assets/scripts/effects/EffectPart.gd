## Written by Claude (claude-opus-5-5), 2026-11-10: one thing an Effect does. The base for the parts in an Effect's parts list, which the
## inspector offers as a dropdown of these classes. Pawn spec 8.11.
##
## Two kinds:
##   do once  runs when an effect is applied (an instant one), or when an over-time one is first applied and then every period.
##            Override apply_once(). On the authority only (EffectManager calls it), so it may change Health and start abilities.
##   held     holds while an over-time effect lasts, and stops when it ends. Override is_held() to return true; the EffectManager
##            reads the part's settings whenever its active list changes. Works on every machine.
##
## A new kind of part: extend this (or a part like it), give it @export settings, and do one of the two above. Parts keep no state
## of their own while playing: one part is shared by every pawn the effect lands on, so anything that changes lives on the pawn.
class_name EffectPart
extends Resource


## True for a part that holds while its effect lasts, instead of running once.
func is_held() -> bool:
	return false


## Runs a do-once part on the pawn the effect landed on. application says who, from whom, how many stacks and what resistance
## applies, and collects results such as the damage dealt.
func apply_once(_application: EffectApplication) -> void:
	pass
