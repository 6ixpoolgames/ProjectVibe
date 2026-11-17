# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## The state for when nothing else fits: its prerequisites always hold.
##
## It has the lowest priority and catches every case the other states don't. Every state manager should have one, or there are
## moments when no state fits.
## Design: pawn spec 10.6.
class_name AIIdleState
extends AIStateBase


func prerequisites_met(_context: AIContextComponent) -> bool:
	return true
