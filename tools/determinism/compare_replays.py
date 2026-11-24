# Written by Claude (claude-opus-5-5), 2026-11-22: judges determinism across separate sessions from their replay recordings (the
# owner's request), without the determinism check's own run. Every offline game records a replay (replay v0); two sessions that start
# the same and play the same record the same thing tick for tick. This compares recordings with
# assets/scripts/samples/tests/replay_compare.tscn, which names the first tick, pawn and field that differ.
#
# Run from the project folder (it starts Godot itself, one at a time):
#   python tools/determinism/compare_replays.py A.pbreplay B.pbreplay      two recordings
#   python tools/determinism/compare_replays.py --latest                   the two newest headless offline recordings
#   python tools/determinism/compare_replays.py --latest --count 4 --folder user://replays/host   the four newest of a game played by hand
#   python tools/determinism/compare_replays.py --sessions 3 --size 100 --ticks 3600
# --sessions N plays the mass battle N times, each a separate headless session (--offline, quitting after --ticks), then compares each
# recording with the first. By default each runs in real time, as a player's game does, and with the load ladder pinned (--ladder
# leaves it working: it follows how busy the machine is, so it differs by session). --fixed-fps runs each as fast as it can instead,
# one tick a frame. --arg passes an argument on to the sample (--arg=--spawn-distance=40). --details N lists that many pawns at the
# first difference. Exit code 0: the recordings agree; 1: they differ; 2: a run or a file failed. Recordings beyond the recorder's
# keep_recordings (100 a folder) are deleted, so at most 100 sessions.
# Godot is looked for beside the project folder, as tools/run_tests.sh does; set GODOT to use another.
import argparse
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPARE_SCENE = "res://assets/scripts/samples/tests/replay_compare.tscn"
BATTLE_SCENE = "res://assets/scenes/samples/mass_battle_sample.tscn"
HEADLESS_FOLDER = "user://replays/headless/host"
GODOT = os.environ.get("GODOT", str(ROOT.parent / "Godot_v4.7.2-stable_win64_console.exe"))


def godot(arguments, scene, user_args, timeout=None):
    command = [GODOT, "--headless"] + arguments + ["--path", str(ROOT), scene, "--"] + user_args
    return subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)


def play_session(number, args):
    user_args = ["--offline", "--team-size=%d" % args.size, "--quit-after-ticks=%d" % args.ticks] + args.arg
    if not args.ladder:
        user_args.append("--no-load-ladder")
    engine_args = ["--fixed-fps", "60"] if args.fixed_fps else []
    # Real time: the ticks take ticks / 60 seconds if the machine keeps up, more if it can't. A generous limit, for a stuck run.
    result = godot(engine_args, BATTLE_SCENE, user_args, timeout=max(600, args.ticks))
    errors = [line for line in (result.stdout + result.stderr).splitlines() if "SCRIPT ERROR" in line]
    print("  session %d: exit %d%s" % (number, result.returncode, ", %d script errors" % len(errors) if errors else ""))
    if result.returncode != 0 or errors:
        print("\n".join((errors or result.stderr.splitlines())[-10:]))
        sys.exit(2)


def main():
    parser = argparse.ArgumentParser(description="Compare replay recordings tick by tick.")
    parser.add_argument("files", nargs="*", help="two .pbreplay files")
    parser.add_argument("--latest", action="store_true", help="compare the newest recordings in --folder")
    parser.add_argument("--folder", default=HEADLESS_FOLDER)
    parser.add_argument("--count", type=int, default=2)
    parser.add_argument("--sessions", type=int, default=0, help="play the mass battle this many times first")
    parser.add_argument("--size", type=int, default=50, help="each faction's soldiers, for --sessions")
    parser.add_argument("--ticks", type=int, default=3600, help="ticks each session plays, for --sessions")
    parser.add_argument("--ladder", action="store_true", help="leave the load ladder working")
    parser.add_argument("--fixed-fps", action="store_true", help="one tick a frame, as fast as it can, instead of real time")
    parser.add_argument("--arg", action="append", default=[], help="an argument for the sample")
    parser.add_argument("--details", type=int, default=10)
    args = parser.parse_args()

    compare_args = ["--details=%d" % args.details]
    if args.sessions:
        if args.sessions < 2 or args.sessions > 10:
            parser.error("--sessions takes 2 to 10")
        print("Playing the mass battle %d times: %d a faction, %d ticks, %s, load ladder %s" % (
            args.sessions, args.size, args.ticks, "one tick a frame" if args.fixed_fps else "real time", "on" if args.ladder else "pinned"))
        for number in range(1, args.sessions + 1):
            play_session(number, args)
        compare_args += ["--latest=" + HEADLESS_FOLDER, "--count=%d" % args.sessions]
    elif args.latest:
        compare_args += ["--latest=" + args.folder, "--count=%d" % args.count]
    elif len(args.files) == 2:
        compare_args += ["--a=" + str(pathlib.Path(args.files[0]).resolve()), "--b=" + str(pathlib.Path(args.files[1]).resolve())]
    else:
        parser.error("give two files, --latest, or --sessions N")

    result = godot([], COMPARE_SCENE, compare_args)
    lines = [line for line in result.stdout.splitlines() if line.strip() and not line.startswith("Godot Engine")]
    print("\n".join(lines))
    errors = [line for line in result.stderr.splitlines() if "SCRIPT ERROR" in line]
    if errors:
        print("\n".join(errors[-10:]))
        sys.exit(2)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
