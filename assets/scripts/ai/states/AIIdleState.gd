## Written by Claude (claude-opus-5-5), 2026-11-09: the state for when nothing else fits. Pawn spec section 10.6.
##
## Its prerequisites always hold, so with the lowest priority it catches every case the other states don't. Every state manager
## should have one, or there are moments when no state fits.
class_name AIIdleState
extends AIStateBase


func prerequisites_met(_context: AIContextComponent) -> bool:
	return true
