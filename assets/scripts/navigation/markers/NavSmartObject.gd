# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## A point that AI can use, with room for a limited number of users: a smart object (nav spec section 21.3).
##
## Tags such as use.seat, use.work and use.pickup say how it's used.
## Who is using it right now changes during play, so that belongs to NavSmartObjectModule, not to this data.
class_name NavSmartObject
extends NavPoint

## How many users fit at once.
@export var slot_count := 1
