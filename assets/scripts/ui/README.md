<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the ui system's overview, beside its code. -->

# UI

Menus built from the game's own settings. For now, one piece: the start menu's match options.

**Status:** partly built, tier 0. Not yet: rows for settings other than true-or-false, choices and numbers.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview |
| [REFERENCE.md](REFERENCE.md) | Every class and function, generated from the code's doc comments (`python tools/docs/make_reference.py ui`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why |

## The pieces

- **`MatchOptionsPanel`**: a list of rows, one per setting, made from the setting's own export (a check box, a drop-down or a number box). Every GameMode module that names settings (`get_match_options`) shows up by itself.

## How to use it

**Offer a module's settings in the menu.** In the module, return their names from `get_match_options()`. The panel picks them up with `add_from_game_mode()`.

**Add a level's own settings.**
```gdscript
panel.add_section("This level", self, PackedStringArray(["team_size", "spawn_distance"]))
```

Call `refresh()` when the menu is shown. The arena samples' "Match options" button shows it working.

## Tests

No tests of its own; `game_mode/tests/game_mode_selftest` builds panels from modules and autoloads.
