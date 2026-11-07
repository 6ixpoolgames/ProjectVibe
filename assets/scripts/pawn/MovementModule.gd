## Written by Claude (claude-opus-5-5), 2026-11-07: the base for one way of moving, attached to a Pawn as a child.
## GroundMovement is the first. Swapping the module changes how a pawn moves without changing the pawn, the way Unreal has
## CharacterMovementComponent and FloatingPawnMovement. A module holds no state that affects the future unless it lists it in
## the pawn's TickState, because rollback has to be able to restore it.
##
## A module works out the pawn's velocity. The Pawn makes the single move_and_slide call afterwards.
##
## Claude 2026-11-07: a placeholder until abilities exist. The current direction, which is work in progress, has no movement modules:
## locomotion abilities such as Walk and Fly write velocity directly. See docs/pawn/PAWN_ARCHITECTURE.md section 9.
class_name MovementModule
extends Node


## Sets up the pawn's velocity and facing for one tick, from the input on the pawn.
func simulate(_pawn: Pawn, _dt: float) -> void:
	pass
