# Written by Claude (claude-opus-5-5), 2026-11-25. History: navigation/CHANGELOG.md.
## How a [PathFollower] follows its path: how close counts as there, which nav, links, and how long it waits for nav.
##
## One resource, shared by every follower given it: a [MoveStep] exports one, and so does the [AIController] for its own walks.
## A follower with none uses the defaults below. Followers read it as they go, so a change takes hold at once; make a new one for a
## pawn that should differ rather than changing a shared one. Ticks are written for 60 a second.
class_name PathFollowSettings
extends Resource

## How close, in metres, the pawn must get to a corner of the path before it heads for the next one. Measured flat, ignoring height,
## because a path's height between corners isn't the ground.
@export var corner_reached_distance := 0.5
## How close, in metres, it must get to the end of the path to count as arrived. Smaller than corner_reached_distance, because the
## end is where something wanted to be.
@export var arrival_distance := 0.3
## Which size of nav to use. 0 is the smallest. The nav spec's tiers are by pawn radius; t0 builds only tier 0.
@export var nav_tier := 0
## On, paths may cross links (jumps, drops, placed links). Off for a pawn that can't jump, so it only goes where it can walk.
@export var use_links := true
## How long the pawn has to get from a link's start to its end, in ticks. Past that it finds a new path, from wherever it ended up,
## to the same place; missing again, it gives up. 180 is 3 s.
@export_range(1, 3600, 1, "or_greater") var link_timeout_ticks := 180
## On, a move where there's no nav at all, and none being built, walks in a straight line (bare test levels, click-to-move without
## nav). Off, there's no way there, for a game where walking off the nav would be a bug.
@export var straight_line_without_nav := true
## While waiting for nav to be built under the pawn, how often it tries again to find a path, in ticks.
@export_range(1, 600, 1, "or_greater") var pending_retry_ticks := 10
## How long it waits for nav to be built or a queued path to come, in ticks, before giving up. 300 is 5 s.
@export_range(1, 3600, 1, "or_greater") var pending_give_up_ticks := 300
