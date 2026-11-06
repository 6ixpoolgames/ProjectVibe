## Written by Claude (claude-opus-5-5), 2026-11-06: a point that AI can use, with room for a limited number of users (nav spec section 21.3).
## The usual term is a smart object. Tags such as use.seat, use.work and use.pickup say how it's used.
## Who is using it right now changes during play, so that belongs to NavSmartObjectModule, not to this data.
class_name NavSmartObject
extends NavPoint

## How many users fit at once.
@export var slot_count := 1
