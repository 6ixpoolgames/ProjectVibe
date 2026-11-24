# Written by Claude (claude-opus-5-5), 2026-11-24. History: abilities/CHANGELOG.md.
## Taking a hit: an instant action, started by [code]event.hit.taken[/code], that decides what a hit does to its pawn (pawn spec 16.7).
##
## The AbilityManager sends the event as a hit is delivered (on the server, after simulate), and this starts with the hit as its
## trigger data, in its own category, which nothing locks out. Its start requirements decide whether a hit counts at all: by default a
## pawn that owns status.hit_immune ignores it. Otherwise the hit arrives ([signal AbilityManager.hit_arrived], so the AI notes the
## attack) and is either blocked ([signal AbilityManager.hit_blocked]: the pawn is dead, invulnerable, or parrying and facing the
## attacker, whose reply goes back on the next tick) or lands: the status manager applies its effects, [signal AbilityManager.hit_received]
## goes out, then the attacker gets its effects. A game changes what hits do by extending it. The manager adds one to a pawn without.
class_name ReceiveHitAbility
extends AbilityBase

## Why a hit was blocked, as [signal AbilityManager.hit_blocked] gives it.
const BLOCKED_DEAD := &"dead"
const BLOCKED_INVULNERABLE := &"invulnerable"
const BLOCKED_PARRIED := &"parried"


## Its kind's defaults: a new [ReceiveHitDefinition].
func make_default_definition() -> AbilityDefinition:
	return ReceiveHitDefinition.new()


func start() -> void:
	var hit := trigger_data.optional_object as HitInfo if trigger_data else null
	if hit:
		resolve(hit)


## Resolves one hit on this pawn, on the server: it arrives, then it's blocked or it lands (see the class description).
func resolve(hit: HitInfo) -> void:
	manager.hit_arrived.emit(hit)
	var reason := blocked_by(hit)
	if reason != &"":
		manager.hit_blocked.emit(hit, reason)
		return
	if pawn.status_manager:
		pawn.status_manager.take_hit(hit)
	manager.hit_received.emit(hit)
	var attacker := hit.attacker
	if not hit.attacker_effects.is_empty() and is_instance_valid(attacker) and attacker.status_manager:
		attacker.status_manager.apply_effects(hit.attacker_effects, attacker, hit.ability, hit)


## Why this hit is blocked (one of the BLOCKED_ names), or &"" if it lands. A parry that blocks it sends its reply from here.
func blocked_by(hit: HitInfo) -> StringName:
	if pawn.is_dead():
		return BLOCKED_DEAD
	var owned := pawn.owned_tags
	if owned == null:
		return &""
	if owned.has(Tags.STATUS.INVULNERABLE):
		return BLOCKED_INVULNERABLE
	if owned.has(Tags.STATUS.PARRYING) and pawn.status_manager:
		var parry := _parry_facing(hit)
		if parry:
			_reply(hit, parry)
			return BLOCKED_PARRIED
	return &""


# The first held parry whose front the attacker is in, or null. A hit with no attacker (a trap) or from the pawn itself isn't parried.
func _parry_facing(hit: HitInfo) -> ParryModifier:
	var attacker := hit.attacker
	if not is_instance_valid(attacker) or attacker == pawn:
		return null
	for parry in pawn.status_manager.get_parries():
		if parry.faces(pawn, attacker.global_position):
			return parry
	return null


# The parry's reply: a hit of its own on the attacker, delivered on the next tick so two pawns parrying each other can't trade replies
# forever within one tick. The attacker can parry it in turn.
func _reply(hit: HitInfo, parry: ParryModifier) -> void:
	var attacker := hit.attacker
	if parry.reply_effects.is_empty() or attacker.ability_manager == null:
		return
	var away := attacker.global_position - pawn.global_position
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw)) # the way the pawn faces: -Z turned by its yaw
	var no_effects: Array[Effect] = []
	var reply := HitInfo.make(pawn, null, attacker, away, hit.tick, parry.reply_effects, no_effects)
	attacker.ability_manager.receive_hit(reply, 1)
