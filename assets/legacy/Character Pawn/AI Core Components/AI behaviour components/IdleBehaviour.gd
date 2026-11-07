## Written by Claude (claude-opus-5-5), 2026-11-03: example behaviour. The fallback "do nothing" option.
## Scores low (0.1) so anything that actually wants to run beats it, but it's always available,
## so a pawn with nothing better to do stands still instead of keeping its last move order.
extends AIBehaviourComponentBase
class_name IdleBehaviour


func _init() -> void:
	base_score = 0.1
	interrupt_policy = InterruptPolicy.ALWAYS # Claude 2026-11-04: idle never finishes, so it must yield to anything better


func enter(context: AIContext) -> void:
	context.stop_moving()
