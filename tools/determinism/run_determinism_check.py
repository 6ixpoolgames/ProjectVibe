# Written by Claude (claude-opus-5-5), 2026-11-22: the determinism check (the owner's request). Plays the same match twice on this
# machine, from the same start, and compares a fingerprint of the state store after every tick: the standard desync checksum. If the
# runs ever differ, it plays both again with a dump of every row around the first differing tick, and names the entities and columns
# that went apart, with both values. One difference anywhere grows, so the first one is the one to fix.
#
# Run from the project folder (it starts Godot itself, one run at a time):
#   python tools/determinism/run_determinism_check.py                 the mass battle, 20 a faction, 1200 ticks
#   python tools/determinism/run_determinism_check.py --size 50 --ticks 3600 --runs 4 --ladder
# --runs N plays it N times and compares each with the first (a difference that comes and goes needs several). --ladder leaves the
# load ladder working (it follows how loaded the machine is, so it's a known source of difference). --arg passes an argument on to
# the run or the sample (--arg=--spawn-distance=40; --arg=--workers=0 runs every job on the main thread). --keep DIR keeps the files. Exit code 0: the runs agree; 1: they differ; 2: a run failed.
# Godot is looked for beside the project folder, as tools/run_tests.sh does; set GODOT to use another.
#
# The run itself: assets/scripts/samples/tests/determinism_check.gd. Design: state store spec (deterministic replay).
import argparse
import os
import pathlib
import struct
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCENE = "res://assets/scripts/samples/tests/determinism_check.tscn"
GODOT = os.environ.get("GODOT", str(ROOT.parent / "Godot_v4.7.2-stable_win64_console.exe"))


def run(out, extra, label):
    command = [GODOT, "--headless", "--fixed-fps", "60", "--path", str(ROOT), SCENE, "--", "--out=" + str(out)] + extra
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
    errors = [line for line in result.stdout.splitlines() + result.stderr.splitlines() if "SCRIPT ERROR" in line]
    if result.returncode != 0 or errors or not out.exists():
        print("%s failed (exit %d)" % (label, result.returncode))
        print("\n".join((errors or result.stderr.splitlines())[-20:]))
        sys.exit(2)


def read_fingerprints(path):
    """tick -> (checksum, {handle: row hash}, [column hash, layout by layout])"""
    data = path.read_bytes()
    ticks, at = {}, 0
    while at < len(data):
        tick, checksum = struct.unpack_from("<qq", data, at)
        count = struct.unpack_from("<i", data, at + 16)[0]
        at += 20
        rows = {}
        for _ in range(count):
            handle, row = struct.unpack_from("<qq", data, at)
            rows[handle] = row
            at += 16
        width = struct.unpack_from("<i", data, at)[0]
        at += 4
        columns = list(struct.unpack_from("<%dq" % width, data, at))
        at += 8 * width
        ticks[tick] = (checksum, rows, columns)
    return ticks


def read_names(path):
    """[column label: landings, then layout by layout], {handle: node path}"""
    columns, entities = ["landings (chunks and nav tiles, LandingLog)"], {}
    names = pathlib.Path(str(path) + ".names")
    if names.exists():
        for line in names.read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if parts[0] == "layout":
                columns += ["layout %s: %s" % (parts[1], name) for name in parts[2:]]
            elif parts[0] == "entity":
                entities[int(parts[1])] = parts[2]
    return columns, entities


def first_difference(a, b):
    """The first tick where the runs differ, and the handles that differ there (or are only in one)."""
    for tick in sorted(set(a) | set(b)):
        if tick not in a or tick not in b:
            return tick, ["(the tick is only in one run)"]
        (sum_a, rows_a, _), (sum_b, rows_b, _) = a[tick], b[tick]
        if sum_a != sum_b or rows_a != rows_b:
            handles = sorted(h for h in set(rows_a) | set(rows_b) if rows_a.get(h) != rows_b.get(h))
            return tick, handles
    return None, []


def differing_columns(a, b, tick, labels):
    cols_a, cols_b = a[tick][2], b[tick][2]
    if len(cols_a) != len(cols_b):
        return ["(the runs have different layouts)"]
    return [labels[i] if i < len(labels) else "column %d" % i for i in range(len(cols_a)) if cols_a[i] != cols_b[i]]


def read_dump(path):
    """(tick, handle, column) -> (owner, hash, value)"""
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        tick, handle, owner, column, value_hash, value = line.split("\t", 5)
        out[(int(tick), int(handle), column)] = (owner, value_hash, value)
    return out


def main():
    parser = argparse.ArgumentParser(description="Plays the same match twice and compares the state store after every tick.")
    parser.add_argument("--size", type=int, default=20, help="soldiers per faction (default 20)")
    parser.add_argument("--ticks", type=int, default=1200, help="ticks to play (default 1200, 20 s)")
    parser.add_argument("--ladder", action="store_true", help="leave the load ladder working")
    parser.add_argument("--runs", type=int, default=2, help="how many runs, each compared with the first (default 2)")
    parser.add_argument("--arg", action="append", default=[], help="an argument passed on to the sample, such as --arg=--spawn-distance=40")
    parser.add_argument("--keep", help="a folder to keep the files in")
    parser.add_argument("--show", type=int, default=12, help="differing columns to list (default 12)")
    args = parser.parse_args()
    folder = pathlib.Path(args.keep) if args.keep else pathlib.Path(tempfile.mkdtemp(prefix="determinism_"))
    folder.mkdir(parents=True, exist_ok=True)
    extra = ["--size=%d" % args.size, "--ticks=%d" % args.ticks] + (["--ladder"] if args.ladder else []) + args.arg
    print("Determinism check: team size %d, %d ticks, load ladder %s" % (args.size, args.ticks, "on" if args.ladder else "off"))
    first = None
    for n in range(1, max(args.runs, 2) + 1):
        out = folder / ("run%d.bin" % n)
        run(out, extra, "Run %d" % n)
        fingerprints = read_fingerprints(out)
        if first is None:
            first = fingerprints
            continue
        tick, handles = first_difference(first, fingerprints)
        print("  run %d against run 1: %s" % (n, "the same" if tick is None else "differs from tick %d" % tick))
        if tick is not None:
            runs = [first, fingerprints]
            break
    else:
        print("The runs agree: %d runs of %d ticks, every entity's row the same every tick." % (max(args.runs, 2), len(first)))
        return 0
    print("The runs differ from tick %d (%d ticks in), in %d entities." % (tick, tick - min(runs[0]), len(handles)))
    labels, entities = read_names(folder / "run1.bin")
    print("Runs 1 and %d:" % n)
    for handle in handles[:args.show]:
        print("  entity %s" % entities.get(handle, handle))
    print("  columns: %s" % ", ".join(differing_columns(runs[0], runs[1], tick, labels)))
    later = sum(1 for t in runs[0] if t in runs[1] and runs[0][t][:2] != runs[1][t][:2])
    print("  %d of %d ticks differ in all." % (later, len(runs[0])))
    # Again, with every row around that tick written out, to name what differs.
    dumps = []
    window = ["--dump-from=%d" % (tick - 1), "--dump-to=%d" % (tick + 1)]
    for name in ("dump_a", "dump_b"):
        dump = folder / (name + ".txt")
        run(folder / (name + ".bin"), extra + window + ["--dump=" + str(dump)], "Dump run " + name[-1])
        dumps.append(read_dump(dump))
    again, _ = first_difference(read_fingerprints(folder / "dump_a.bin"), read_fingerprints(folder / "dump_b.bin"))
    if again != tick:
        print("(The two dump runs first differ at tick %s, not %d: the difference comes and goes, so the values below may not show it.)" % (again, tick))
    a, b = dumps
    keys = sorted(set(a) | set(b))
    shown = 0
    for key in keys:
        if a.get(key, (None, None))[1] == b.get(key, (None, None))[1]:
            continue
        owner = (a.get(key) or b.get(key))[0]
        print("  tick %d  %s  %s:\n      %s\n      %s" % (key[0], owner, key[2], (a.get(key) or ("", "", "(missing)"))[2],
              (b.get(key) or ("", "", "(missing)"))[2]))
        shown += 1
        if shown >= args.show:
            break
    if shown == 0:
        print("  The dumps around that tick agree: the dump runs didn't go apart there.")
    print("Files: %s" % folder)
    return 1


if __name__ == "__main__":
    sys.exit(main())
