# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Keeps about [member FollowStep.stop_distance] from a target (flat), closing in when further and backing away when nearer, and stands
## once within [member FollowStep.band] of that distance (half of it, from walking) (pawn spec 16.7's KeepAwayFrom).
##
## Otherwise as [FollowStep]: a ranged pawn hanging back at shooting distance runs one ([AIKeepDistanceBehaviour]).
class_name KeepAwayFromStep
extends FollowStep


func _init() -> void:
	super()
	stop_distance = 8.0
	band = 1.5


func goal_for(there: Vector3, away: Vector3, distance: float) -> Vector3:
	var direction := away / distance if distance > 0.01 else pawn.global_basis.z
	return there + direction * stop_distance


func off_by(distance: float) -> float:
	return absf(distance - stop_distance)
