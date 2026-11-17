# Written by Claude (claude-opus-5-5), 2026-11-18. History: tools/docs/README.md (the comment section it checks).
# Measures GDScript comments against the reference style in tools/docs/README.md ("Comments in code"), so the wiki's reference pages
# stay short and readable. Production code only: tests/, samples/ and debug/ folders and assets/legacy/ are left out, since tests and
# samples may keep dated notes.
#
# What it counts, per system folder under assets/scripts/:
#   class_doc   a class's ## comment longer than CLASS_LINES lines
#   member_doc  a member, signal, constant or function ## comment longer than MEMBER_LINES lines
#   teaching    a "GDScript note:" comment
#   dated       a dated note ("Claude 2026-11-09") in a comment
#   history     decision history in a ## comment ("the owner's call", "was ...", "used to")
#
# Run from the project folder:
#   python tools/docs/check_comment_style.py                 every system, a table of counts
#   python tools/docs/check_comment_style.py ai stats        these systems, with each find listed
#   python tools/docs/check_comment_style.py --strict ...    exit 1 if anything is found
import os
import re
import sys

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPTS = os.path.join(PROJECT, "assets", "scripts")
SKIP_FOLDERS = {"tests", "samples", "debug", "legacy"}
CLASS_LINES = 14
MEMBER_LINES = 3
DATED = re.compile(r"Claude 20\d\d-\d\d-\d\d")
HISTORY = re.compile(r"the owner's call|\bused to\b|\(was [^)]*\)|\bwas previously\b", re.IGNORECASE)
DECLARATION = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*(static\s+)?(func|var|const|signal|enum|class)\b")


def files_of(system: str) -> list:
    found = []
    for folder, subfolders, files in os.walk(os.path.join(SCRIPTS, system)):
        subfolders[:] = [name for name in subfolders if name not in SKIP_FOLDERS]
        found += [os.path.join(folder, name) for name in files if name.endswith(".gd")]
    return sorted(found)


def check_file(path: str) -> list:
    finds = []
    lines = open(path, encoding="utf-8").read().split("\n")
    block = [] # the ## lines just above the current line
    block_start = 0
    class_doc_done = False
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if "GDScript note" in line:
            finds.append(("teaching", number))
        if DATED.search(line) and not stripped.startswith("# Written by"):
            finds.append(("dated", number))
        if stripped.startswith("##"):
            if not block:
                block_start = number
            block.append(stripped)
            if HISTORY.search(stripped):
                finds.append(("history", number))
            continue
        if block:
            # The block ends here: a class comment ends at class_name/extends (the file's first block), a member's at its declaration.
            is_class = not class_doc_done and (stripped.startswith("class_name") or stripped.startswith("extends"))
            if is_class:
                class_doc_done = True
                if len(block) > CLASS_LINES:
                    finds.append(("class_doc", block_start))
            elif DECLARATION.match(line) and len(block) > MEMBER_LINES:
                finds.append(("member_doc", block_start))
            block = []
        if stripped.startswith("class_name") or stripped.startswith("extends"):
            class_doc_done = True
    return finds


def main() -> int:
    args = sys.argv[1:]
    strict = "--strict" in args
    systems = [a for a in args if not a.startswith("--")]
    listing = bool(systems)
    if not systems:
        systems = sorted(name for name in os.listdir(SCRIPTS) if os.path.isdir(os.path.join(SCRIPTS, name)) and name not in SKIP_FOLDERS)
    kinds = ["class_doc", "member_doc", "teaching", "dated", "history"]
    total = 0
    print("%-14s %6s %10s %11s %9s %6s %8s" % ("system", "files", "class_doc", "member_doc", "teaching", "dated", "history"))
    for system in systems:
        counts = dict.fromkeys(kinds, 0)
        paths = files_of(system)
        details = []
        for path in paths:
            for kind, number in check_file(path):
                counts[kind] += 1
                details.append("  %s:%d  %s" % (os.path.relpath(path, PROJECT).replace(os.sep, "/"), number, kind))
        total += sum(counts.values())
        print("%-14s %6d %10d %11d %9d %6d %8d" % (system, len(paths), *[counts[k] for k in kinds]))
        if listing:
            for line in details:
                print(line)
    print("total finds: %d" % total)
    return 1 if strict and total > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
