# Written by Claude (claude-opus-5-5), 2026-11-17: checks that a comment cleanup changed only comments. For each GDScript or C++ file
# given (or every changed .gd, .cpp and .h file, with none given), it compares the file with its committed version after removing
# comments and blank lines, and reports any code line that differs. The documentation pass uses it before each commit.
#
# Run from the project folder:
#   python tools/docs/check_comments_only.py                       every .gd, .cpp and .h file changed since the last commit
#   python tools/docs/check_comments_only.py path/to/file.gd ...   only these
#   python tools/docs/check_comments_only.py --against <commit>    compare with another commit instead of HEAD
# Exits 0 when only comments changed, 1 otherwise.
import subprocess
import sys


def code_lines(text: str, marker: str) -> list:
    lines = []
    for line in text.split("\n"):
        code = strip_comment(line, marker).rstrip()
        if code.strip():
            lines.append(code)
    return lines


# The line without its comment (marker: "#" for GDScript, "//" for C++). A marker inside a string isn't a comment, so quotes are
# tracked (strings don't span lines here, and the C++ has no /* */ comments).
def strip_comment(line: str, marker: str) -> str:
    quote = ""
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = ""
        elif c in "\"'":
            quote = c
        elif line.startswith(marker, i):
            return line[:i]
        i += 1
    return line


def main() -> int:
    args = sys.argv[1:]
    against = "HEAD"
    if len(args) >= 2 and args[0] == "--against":
        against = args[1]
        args = args[2:]
    changed = subprocess.run(["git", "diff", "--name-only", against, "--", "*.gd", "*.cpp", "*.h"], capture_output=True, text=True)
    files = args or [f for f in changed.stdout.split() if f]
    failures = 0
    for path in files:
        old = subprocess.run(["git", "show", "%s:%s" % (against, path)], capture_output=True, text=True, encoding="utf-8")
        if old.returncode != 0:
            print("new file, not checked: %s" % path)
            continue
        marker = "#" if path.endswith(".gd") else "//"
        with open(path, encoding="utf-8") as current:
            new_lines = code_lines(current.read(), marker)
        old_lines = code_lines(old.stdout, marker)
        if new_lines == old_lines:
            continue
        failures += 1
        print("CODE CHANGED: %s" % path)
        for index, (a, b) in enumerate(zip(old_lines, new_lines)):
            if a != b:
                print("  first difference, code line %d:\n    was: %s\n    now: %s" % (index + 1, a.strip(), b.strip()))
                break
        else:
            print("  %d code lines before, %d now" % (len(old_lines), len(new_lines)))
    print("%d file(s) checked, %d with code changes" % (len(files), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
