## Written by Claude (claude-opus-5-5), 2026-11-16: facts about where this run of the game is, asked in one place. So far: whether it has a
## display. The code audit found the same check, DisplayServer.get_name() == "headless", written out in about seven places
## (diagnostics, replays, visuals), and two visual parts each with their own switch for tests.
##
## Use:
##   if RunEnvironment.is_headless(): ...        # nothing is drawn: a test, or a dedicated server (Godot started with --headless)
##   if not RunEnvironment.runs_visuals(): ...   # a visual-only part (a toy figure, a floating sword) has nothing to do
## A test that checks visual parts while running headless turns visuals_without_display on.
class_name RunEnvironment
extends RefCounted

## On: visual-only parts run even with no display. Off (the default): with no display they build nothing and never run, since nothing
## can see them (the floating swords cost 1.4 ms a tick on a headless mass battle server). GDScript note: a static var belongs to the
## class, so every part sees the same one.
static var visuals_without_display := false


## True when nothing is drawn: Godot was started headless, as tests and dedicated servers are.
static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


## True if visual-only parts should run: there's a display, or visuals_without_display is on.
static func runs_visuals() -> bool:
	return visuals_without_display or not is_headless()
