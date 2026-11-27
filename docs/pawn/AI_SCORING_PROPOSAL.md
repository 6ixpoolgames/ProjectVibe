<!-- Written by Claude (claude-opus-5-5), 2026-11-27. A proposal for the owner's review; once agreed it folds into pawn spec 10.7, 10.8 and 16.5. -->

# AI scoring: one model, cheaper decisions (proposal)

**Status:** built 2026-11-27, folded into pawn spec 10.7, 10.8 and 10.13 and scaling spec 6.2. Replaces the scoring parts of pawn spec 10.7/10.8 and the score curves of scaling spec 6.2.

**As built:**
- **The setting is `base_score`, not `score`.** On the node, `score` is the `score()` method, so `get("score")` would return the method.
- **The walk asks `is_available()` before "could its action start?"** Availability is usually judged from data, for nothing, and usually fails, while asking an ability costs a call. That cut GDScript's answers from 65 168 to 9 040 in the measurement below.

**Measured after** (the same fight: the same 32 655 decisions, the same deaths, ms a frame at size 25):

| Part | Before | After |
|---|---|---|
| C++ decider call | 0.30 | 0.13 |
| → copying facts | 0.25 | 0.04 |
| → C++ deciding, now with GDScript's answers on the way | 0.02 | 0.07 |
| AI step, all pawns | 2.2 | about 2.1 |
| Whole tick | 8.4 | 8.8 to 9.1 (the same run's own spread; the earlier run was quieter) |

## Why

- **Scoring drifted from the intent.** The spec (10.7, written by Claude) made `max_score` and `min_score` settings. The intent: a behaviour has one score, and "max" and "min" are just that score plus and minus jitter.
- **Four tools overlap:** max/min score, score curves (unused outside tests), persistence (now flat start/end modifiers, its easing lost) and the score bonus (where a multiply does nothing).
- **The decision isn't where the time goes** (below).

## What it costs today

The mass battle, size 25 (about 97 AI pawns), 60 ticks a second, C++ deciding, `--scopes`. Milliseconds a frame:

| Part | ms | Note |
|---|---|---|
| Whole tick | 8.4 | 50% of the budget |
| AI step, all pawns | 2.2 | |
| → deciding (target 0.06, state 0.08, behaviour 0.49) | 0.65 | 9 decisions a frame |
| → → C++ decider call | 0.30 | |
| → → → copying facts into C++ | 0.25 | of which 0.17 is asking which actions could start |
| → → → **C++ deciding itself** | **0.02** | |
| → sensing | 0.46 | |
| → running behaviours' ticks | 0.30 | |
| → the step's own overhead | ~0.8 | calls and checks per pawn, plus the timing scopes' own cost |
| Abilities (outside the AI) | 1.89 | |
| Input commands (outside the AI) | 1.09 | |

**Takeaway:** C++ decides in 0.02 ms. Asking GDScript "could this action start?" costs eight times that, because the abilities' readiness changes almost every decision in a fight. Curves would cost nothing measurable here either way. Most of the AI's time is per-pawn GDScript: the step itself, sensing and behaviour ticks.

## The model

- **Score:** one open number per behaviour, like an ability's `priority`. `max_score` and `min_score` go.
- **Modifiers are the one tool that changes a behaviour's numbers:**
  - multiply, then add, or override;
  - on its score, jitter, interrupt threshold, cooldown or minimum run;
  - or block it.
  - Stat modifiers follow the same rule.
- **A modifier can follow a curve.**
  - Its curve is an optional drawn `Curve`, with strength from −1 to 1.
  - x is either time since the modifier was added or an input (target distance, awareness).
  - Strength scales the change: multiply becomes `1 + (m − 1) × s`, and add becomes `a × s`.
  - Negative strength reverses the change, so a behaviour can drop below its base score for a while. A reversed multiply stops at ×0 (reversing ×3 would otherwise give ×−1).
  - This replaces score curves, and brings back persistence's easing.
- **A behaviour's own modifiers:** always on, on start, and on end.
- **Jitter:** ± on the final score.
  - Its amount is set per behaviour, as a pawn default, or as a game default (a GameMode module).
  - It's drawn either every decision or once per pawn (a fixed personality).
- **Pruning stays exact:** a behaviour's ceiling is `score × multiply + add` (with each curve's highest sample) + jitter.

**Example, Chase:** score 50.
- On start it gets interrupt threshold +40, easing to 0 over 2 s: hard to pull off a fresh chase.
- It also gets score ×1.3, easing to ×0.8 by 10 s, so after a long chase other behaviours get a turn.

## What goes, what's renamed

- **Goes:**
  - `max_score`, `min_score`, `AIScoreCurve` and `score_curves`;
  - the score bonus as a number starting from 0 (it becomes the score itself);
  - the bridge's copy of the hard rules, and asking scripted behaviours up front;
  - `enabled` in the brain key (it becomes a per-pawn mask, so toggling it builds no brain).
- **Renamed:** `manager.cpp` becomes `manager.cpp_decider`.

## Making decisions cheaper

| Change | Exact? | Expected at size 25 |
|---|---|---|
| C++ asks back, through one callback, only for a behaviour still in the running: "could its action start?" and a scripted behaviour's answers | yes | the 0.17 ms readiness cost falls to roughly 0.05; scripted behaviours are asked lazily, as GDScript asks them |
| C++ works out inputs when first read (today it works out all of them, even when the running behaviour is kept) | yes | small now; grows with inputs per brain |
| A time curve past its end folds into the fixed numbers (a tick deadline) | yes | curves cost nothing once settled |

The C++ decider call should drop from about 0.30 to about 0.1 ms a frame: roughly 0.2 of the tick's 8.4 ms. That's worth having, but the big costs are the per-pawn GDScript ones in the table. They need their own measurement and proposal (batching, moving the AI step's phases to C++, decision rate by importance).

## Work

1. The model and modifier curves, in both twins and the brain description; spec 10.7/10.8 rewritten; the samples' behaviour files converted.
2. The ask-back callback for readiness and scripted behaviours; the mirror goes.
3. Lazy inputs in C++; ended curves fold.
4. `enabled` as a mask; the rename.
5. The same measurement again, for before and after.

Tests: the decider comparisons and shadow mode at every decision, the definition tests, the mass battle. Size: L (several sessions). Item 1 is most of it.

## For you to decide

1. Is a curve's strength from −1 to 1 enough? Bigger changes come from the modifier's own numbers.
2. ~~Build jitter's once-per-pawn mode now?~~ **Agreed: build it** (2026-11-27).
3. ~~Keep scripted `score()` overrides, returning an open score?~~ **Agreed: they stay**, a platform for several games (2026-11-27).

Strength from -1 to 1 was confirmed as asked: negative strength reverses the change, and going above the score comes from the modifier's own numbers.
