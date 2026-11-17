# Written by Claude (claude-opus-5-5), 2026-11-16. History: platform/README.md.
## Facts about where this run of the game is, asked in one place. So far: whether it has a display.
##
## Use:
## [codeblock]
## if RunEnvironment.is_headless(): ...        # nothing is drawn: a test, or a dedicated server (Godot started with --headless)
## if not RunEnvironment.runs_visuals(): ...   # a visual-only part (a toy figure, a floating sword) has nothing to do
## [/codeblock]
## A test that checks visual parts while running headless turns [member visuals_without_display] on.
class_name RunEnvironment
extends RefCounted

## On: visual-only parts run even with no display. Off (the default): with no display they build nothing and never run, since nothing
## can see them (the floating swords cost 1.4 ms a tick on a headless mass battle server).
# REFACTOR: a switch only tests turn on, kept in shipping code; test code belongs in tests/. It could stay as the agreed small hook.
static var visuals_without_display := false


## True when nothing is drawn: Godot was started headless, as tests and dedicated servers are.
static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


## True if visual-only parts should run: there's a display, or visuals_without_display is on.
static func runs_visuals() -> bool:
	return visuals_without_display or not is_headless()
