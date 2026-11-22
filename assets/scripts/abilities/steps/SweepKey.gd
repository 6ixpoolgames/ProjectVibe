# Written by Claude (claude-opus-5-5), 2026-11-22. History: abilities/CHANGELOG.md.
## One point on a swing's path: where the hit sphere is at one moment of the hit window (ability spec 7).
##
## A [MeleeSweepStep] with keys moves its sphere from key to key in order of [member at], in a straight line between each pair, so an arc
## can curve, dip or reach out mid-swing. Two keys are the plain start and end. Visuals draw the weapon along the same keys
## ([method AbilityStep.weapon_point]), so what's drawn and what hits can't disagree.
class_name SweepKey
extends Resource

## When, through the hit window: 0 its start, 1 its end.
@export_range(0.0, 1.0, 0.01) var at := 0.0
## Degrees from straight ahead, positive to the pawn's left.
@export_range(-360.0, 360.0, 1.0) var angle := 0.0
## Metres above the pawn's feet.
@export var height := 1.0
## Metres from the pawn to the far edge of the hit sphere.
@export_range(0.1, 20.0, 0.05, "or_greater") var reach := 1.8


## A key made in code.
static func make(key_at: float, key_angle: float, key_height: float, key_reach: float) -> SweepKey:
	var key := SweepKey.new()
	key.at = key_at
	key.angle = key_angle
	key.height = key_height
	key.reach = key_reach
	return key
