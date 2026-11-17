<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the ui system's running changelog. History leaves the code comments and lives here,
next to the code. Newest first. -->

# UI changelog

UI is this folder: `MatchOptionsPanel`. Overview: [README.md](README.md).

## Refactor candidates

None found in the documentation pass.

## 2026-11-17

- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup.

## 2026-11-16

- **`MatchOptionsPanel`** (the owner's request, to prove out the GameMode's modularity): a start menu's options built from the settings each GameMode module names (`get_match_options`), plus a level's and the autoloads' (`add_from_autoloads`). An audit fix reads only the new row's value as each row is added, rather than every row.
