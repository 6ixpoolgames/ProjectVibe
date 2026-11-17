<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the platform folder's overview, beside its code. -->

# Platform

`RunEnvironment` answers questions about where this run of the game is, in one place, so the same check isn't written out across the code.

**Status:** built, tier 0. So far it knows only whether there's a display.

- `RunEnvironment.is_headless()`: nothing is drawn (Godot started with `--headless`, as tests and dedicated servers are).
- `RunEnvironment.runs_visuals()`: whether visual-only parts (toy figures, floating swords) should build and run. False headless, unless `visuals_without_display` is on, which a test that checks visual parts turns on.

Every class and function: [REFERENCE.md](REFERENCE.md) (`python tools/docs/make_reference.py platform`). History: added 2026-11-16 by the code audit, which found `DisplayServer.get_name() == "headless"` written out in about seven places (diagnostics, replays, visuals) and two visual parts with their own switches for tests. Refactor candidate: `visuals_without_display` is a switch only tests turn on, in shipping code (marked `REFACTOR:`; size S; the owner may keep it as the agreed hook).
