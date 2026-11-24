# Written by Claude (claude-opus-5-5), 2026-11-24. History: entities/CHANGELOG.md.
## What a gameplay event carries: its tag, who caused it, who it's for, a number and an object (pawn spec 16.9).
##
## Events are tags with payloads, sent to an entity with [method Pawn.send_event], after Unreal's "send gameplay event to actor" and
## its FGameplayEventData. The status manager sends [code]event.health.depleted[/code] and [code]event.damage.taken[/code]; listeners
## connect to [signal Pawn.gameplay_event_received].
## [codeblock]
## var data := GameplayEventData.new()
## data.instigator = attacker
## data.magnitude = 20.0
## pawn.send_event(Tags.EVENT.DAMAGE_TAKEN, data)
## [/codeblock]
class_name GameplayEventData
extends RefCounted

## The event's tag ([code]Tags.EVENT[/code]), set by [method Pawn.send_event].
var tag: StringName = &""
## Who or what caused it (the attacker, the healer), or null.
var instigator: Node = null
## The entity it was sent to, set by [method Pawn.send_event].
var target: Node = null
## A number that goes with it: the damage taken, the Health left.
var magnitude := 0.0
## Anything else it needs: the hit that caused it, say. Null when nothing goes with it.
var optional_object: Object = null
