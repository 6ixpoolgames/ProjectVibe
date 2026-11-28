# Written by Claude (claude-opus-5-5), 2026-11-27: the profiling suite (the owner's request: where the time goes, averaged over a few
# runs so one noisy run doesn't mislead). Plays the mass battle several times, one run at a time, each with every timing scope on
# (the detailed ones too), drops the march at the start, and averages each run's rows, then the runs. Prints the phases and every
# scope with its spread across runs, and saves a summary that a later profile can be compared with.
#
# Run from the project folder (it starts Godot itself):
#   python tools/profiling/profile_mass_battle.py                       3 runs, size 25, 60 s each, the first 15 s left out
#   python tools/profiling/profile_mass_battle.py --runs 5 --size 50 --seconds 90
#   python tools/profiling/profile_mass_battle.py --compare build/profiles/<earlier>.json     the change since an earlier profile
# --arg passes an argument on to the measure (--arg=--no-ranged). --label names the saved files. Godot is looked for beside the
# project folder, as tools/run_tests.sh does; set GODOT to use another. Exit code 0: done; 2: a run failed.
#
# The measure itself: assets/scripts/samples/tests/mass_battle_measure.gd (--json). Scope names: diagnostics README.
import argparse
import datetime
import json
import os
import pathlib
import statistics
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCENE = "res://assets/scripts/samples/tests/mass_battle_measure.tscn"
GODOT = os.environ.get("GODOT", str(ROOT.parent / "Godot_v4.7.2-stable_win64_console.exe"))
PHASES = ["before_tick", "input", "capture", "simulate", "record", "commit", "after_tick"]
NOISY_SPREAD = 0.05 # a tick time that differs by more than this between runs gets a note


def run_once(index, args, out):
    # The rows come every 10 s; one more second so the last full row is in.
    command = [GODOT, "--headless", "--fixed-fps", "60", "--path", str(ROOT), SCENE, "--",
               "--size=%d" % args.size, "--seconds=%d" % (args.seconds + 1), "--json=" + str(out)] + args.arg
    print("run %d of %d ..." % (index + 1, args.runs), flush=True)
    try:
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace",
                                timeout=args.seconds * 10 + 180)
    except subprocess.TimeoutExpired:
        print("run %d timed out" % (index + 1))
        sys.exit(2)
    errors = [line for line in result.stdout.splitlines() + result.stderr.splitlines() if "SCRIPT ERROR" in line]
    if result.returncode != 0 or errors or not out.exists():
        print("run %d failed (exit %d)" % (index + 1, result.returncode))
        print("\n".join((errors or result.stderr.splitlines())[-20:]))
        sys.exit(2)
    rows = [json.loads(line) for line in out.read_text(encoding="utf-8").splitlines() if line.strip()]
    rows = [row for row in rows if row["second"] > args.skip]
    if not rows:
        print("run %d has no rows after the first %d s" % (index + 1, args.skip))
        sys.exit(2)
    return rows


def average_run(rows):
    """One run's rows averaged: plain numbers, phases (ms a tick) and scopes (ms a tick, calls a tick)."""
    n = len(rows)
    mean = lambda values: sum(values) / n
    run = {key: mean([row[key] for row in rows]) for key in ("pawns", "dead", "tick_ms", "budget_ms", "load_step", "steps_per_frame")}
    run["phases"] = {phase: mean([row["tick_parts"].get(phase, 0.0) for row in rows]) for phase in PHASES}
    names = sorted({name for row in rows for name in row["scopes"]})
    scopes = {}
    for name in names:
        if name.startswith("tick."):
            continue # the phases again, already above
        # Scopes are summed a frame; a frame holds steps_per_frame ticks (1 headless at 60), so per tick is the fairer unit.
        ms = mean([row["scopes"].get(name, [0.0, 0.0])[0] / max(row["steps_per_frame"], 1e-6) for row in rows])
        calls = mean([row["scopes"].get(name, [0.0, 0.0])[1] / max(row["steps_per_frame"], 1e-6) for row in rows])
        scopes[name] = {"ms": ms, "calls": calls}
    run["scopes"] = scopes
    return run


def combine(runs):
    """Mean and spread over runs, for every number."""
    def stats(values):
        return {"mean": statistics.fmean(values), "sd": statistics.stdev(values) if len(values) > 1 else 0.0,
                "min": min(values), "max": max(values)}
    out = {key: stats([run[key] for run in runs]) for key in ("pawns", "dead", "tick_ms", "budget_ms", "load_step", "steps_per_frame")}
    out["phases"] = {phase: stats([run["phases"][phase] for run in runs]) for phase in PHASES}
    names = sorted({name for run in runs for name in run["scopes"]})
    scopes = {}
    for name in names:
        ms = [run["scopes"].get(name, {"ms": 0.0})["ms"] for run in runs]
        calls = [run["scopes"].get(name, {"calls": 0.0})["calls"] for run in runs]
        us_each = [1000.0 * m / c for m, c in zip(ms, calls) if c > 0]
        scopes[name] = {"ms": stats(ms), "calls": stats(calls), "us_each": stats(us_each) if us_each else None}
    out["scopes"] = scopes
    return out


def spread(stat):
    return "+-%.2f" % stat["sd"] if stat["sd"] > 0 else ""


# Scopes timed inside another whose name doesn't say so, and scopes whose name looks nested but isn't (the activation manager runs
# once a frame, outside every pawn's AI). Checked before the names.
INSIDE = [("ai.sense.", "ai.sensing"), ("ai.behaviour.", "ai.behaviours"), ("ai.state.", "ai.decide.state"),
          ("ai.available.", "ai.decide.behaviour"), ("movement.crowd_", "movement.crowd")]
NOT_INSIDE = {"ai.activation"}
STEPS = "steps (all)" # AI steps run inside pawn.input.behaviour_steps, ability steps inside pawn.abilities


def parent_of(name, names):
    """The scope this one is timed inside: a known case, else the longest other name it extends with a dot ("pawn.input" for
    "pawn.input.blocked_check")."""
    if name in NOT_INSIDE:
        return None
    if name.startswith("step."):
        return STEPS
    for prefix, parent in INSIDE:
        if name.startswith(prefix) and parent in names:
            return parent
    parts = name.split(".")
    for cut in range(len(parts) - 1, 0, -1):
        candidate = ".".join(parts[:cut])
        if candidate in names:
            return candidate
    return None


def scope_lines(summary, earlier, min_ms):
    names = dict(summary["scopes"])
    step_ms = [s["ms"]["mean"] for name, s in names.items() if name.startswith("step.")]
    if step_ms: # a heading for the steps, with their sum
        total = {"mean": sum(step_ms), "sd": 0.0, "min": 0.0, "max": 0.0}
        names[STEPS] = {"ms": total, "calls": {"mean": 0.0, "sd": 0.0, "min": 0.0, "max": 0.0}, "us_each": None}
    children = {}
    roots = []
    for name in names:
        parent = parent_of(name, names)
        (children.setdefault(parent, []) if parent else roots).append(name)
    lines = []

    def add(name, depth):
        s = names[name]
        if s["ms"]["mean"] < min_ms and depth > 0:
            return
        each = "%8.1f" % s["us_each"]["mean"] if s["us_each"] else "        "
        change = ""
        if earlier and name in earlier["scopes"]:
            before = earlier["scopes"][name]["ms"]["mean"]
            change = "  %+6.2f" % (s["ms"]["mean"] - before)
        calls = "%8.1f" % s["calls"]["mean"] if s["calls"]["mean"] > 0 else "        "
        lines.append("%-44s %7.2f %6s %s %s%s" % ("  " * depth + name, s["ms"]["mean"], spread(s["ms"]), calls, each, change))
        for child in sorted(children.get(name, []), key=lambda c: -names[c]["ms"]["mean"]):
            add(child, depth + 1)

    for root in sorted(roots, key=lambda r: -names[r]["ms"]["mean"]):
        if names[root]["ms"]["mean"] >= min_ms:
            add(root, 0)
    return lines


def report(summary, earlier, args, runs):
    lines = []
    tick = summary["tick_ms"]
    budget = summary["budget_ms"]["mean"]
    lines.append("Mass battle, size %d, %d runs of %d s (the first %d s left out), %s" % (args.size, len(runs), args.seconds, args.skip,
                 " ".join(args.arg) if args.arg else "default settings"))
    lines.append("pawns %.0f (dead %.0f), load step %.2f, ticks a frame %.2f" % (summary["pawns"]["mean"], summary["dead"]["mean"],
                 summary["load_step"]["mean"], summary["steps_per_frame"]["mean"]))
    line = "tick %.2f ms %s (%.0f%% of the budget); runs %s" % (tick["mean"], spread(tick), 100.0 * tick["mean"] / budget,
                                                             ", ".join("%.2f" % run["tick_ms"] for run in runs))
    if earlier:
        line += "; earlier %.2f (%+.2f)" % (earlier["tick_ms"]["mean"], tick["mean"] - earlier["tick_ms"]["mean"])
    lines.append(line)
    if tick["mean"] > 0 and (tick["max"] - tick["min"]) / tick["mean"] > NOISY_SPREAD:
        lines.append("note: the runs' tick times differ by more than %d%%; more runs, or a quieter machine, would help" % int(NOISY_SPREAD * 100))
    if any(abs(run["load_step"] - 1.0) > 0.01 for run in runs):
        lines.append("note: some rows ran at load step 2 or more, where pawns skip ticks: calls drop and per-tick costs aren't comparable")
    lines.append("")
    lines.append("Phases, ms a tick: " + ", ".join("%s %.2f%s" % (p, s["mean"], " " + spread(s) if spread(s) else "")
                                                for p, s in summary["phases"].items() if s["mean"] >= 0.01))
    lines.append("")
    header = "%-44s %7s %6s %8s %8s" % ("scope (a child is timed inside its parent)", "ms/tick", "sd", "calls", "us each")
    if earlier:
        header += "  change"
    lines.append(header)
    lines.extend(scope_lines(summary, earlier, args.min_ms))
    lines.append("(steps: AI steps run inside pawn.input.behaviour_steps, ability steps inside pawn.abilities)")
    return lines


def main():
    parser = argparse.ArgumentParser(description="Profiles the mass battle over several runs and averages them.")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--size", type=int, default=25)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--skip", type=int, default=15, help="seconds left out at the start (the march)")
    parser.add_argument("--min-ms", type=float, default=0.02, help="scopes cheaper than this (ms a tick) aren't listed")
    parser.add_argument("--arg", action="append", default=[], help="passed on to the measure, as --arg=--no-ranged")
    parser.add_argument("--compare", help="a summary saved by an earlier profile")
    parser.add_argument("--label", default="", help="added to the saved files' names")
    parser.add_argument("--out", default=str(ROOT / "build" / "profiles"))
    args = parser.parse_args()
    earlier = json.loads(pathlib.Path(args.compare).read_text(encoding="utf-8")) if args.compare else None
    runs = []
    with tempfile.TemporaryDirectory() as folder:
        for i in range(args.runs):
            runs.append(average_run(run_once(i, args, pathlib.Path(folder) / ("run%d.jsonl" % i))))
    summary = combine(runs)
    lines = report(summary, earlier, args, runs)
    print("\n".join(lines))
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    stem = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S") + ("_" + args.label if args.label else "")
    (out / (stem + ".json")).write_text(json.dumps(summary, indent=1), encoding="utf-8")
    (out / (stem + ".txt")).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\nsaved: %s (.json to compare with later, .txt the report)" % (out / stem).relative_to(ROOT))


if __name__ == "__main__":
    main()
