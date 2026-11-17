# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## A point AI can use, with room for a limited number of users (nav spec 21.3).
##
## Tags such as use.seat, use.work and use.pickup say how it's used. Who is using it changes during play, so that belongs to
## NavSmartObjectModule, not to this data.
class_name NavSmartObject
extends NavPoint

## How many users fit at once.
@export var slot_count := 1
