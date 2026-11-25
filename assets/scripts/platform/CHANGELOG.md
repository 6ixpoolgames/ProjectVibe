<!-- Written by Claude (claude-opus-5-5), 2026-11-25: the platform folder's running changelog. Newest first. -->

# Platform changelog

The platform folder: `RunEnvironment` (where this run of the game is) and `ScriptOverrides` (whether a script overrides a function).
Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| A switch only tests turn on | `RunEnvironment.visuals_without_display` | Test code belongs in tests/; it could stay as the agreed small hook | S |

## 2026-11-25

- **This changelog** (it had none): the refactor row for `RunEnvironment`'s test switch, which was tagged in the code but listed nowhere.
