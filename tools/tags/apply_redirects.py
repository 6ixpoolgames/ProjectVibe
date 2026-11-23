# Written by Claude (claude-opus-5-5), 2026-11-22: rewrites old tag names in saved files to their new names, from the redirects in
# the tag declarations files (tag spec 5). The runtime already reads an old name as its new one, with a warning; this makes the saved
# files say the new name, so the warnings stop. The redirects themselves stay, so old replays and saves keep loading.
#
# Run from the project folder, with the Godot editor closed (it would write its own copy of an open scene back):
#   python tools/tags/apply_redirects.py            rewrite, and list what changed
#   python tools/tags/apply_redirects.py --dry-run  only list what would change
#
# What it touches: .tres and .tscn files under assets/, only on the lines of properties that hold tags (TAG_PROPERTIES below; add a
# game's own with --property NAME). A quoted name is replaced only when it's a whole redirect key, so "combat" never touches
# "combatant". Scripts aren't rewritten: code uses the Tags constants, and any old name left in a script as a &"..." literal is listed instead.
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE_DECLARATIONS = ROOT / "assets/scripts/resources/tag_declarations.tres"
EXTRA_SETTING = "project_base/tags/extra_declaration_files"

# Properties that hold tags, in the base: abilities (category, extra_categories, locks_out, cancelled_by), effects (tags) and their
# parts (tag, ability_tag), nav markers (tag, action_tag).
TAG_PROPERTIES = {"category", "extra_categories", "locks_out", "cancelled_by", "tags", "tag", "ability_tag", "action_tag"}

LINE = re.compile(r"^(\w+) = (.*)$")
QUOTED = re.compile(r'(&?)"([^"\\]*)"')
REDIRECT = re.compile(r'&"([^"]+)"\s*:\s*&"([^"]+)"')


def declaration_files():
    files = [BASE_DECLARATIONS]
    project = (ROOT / "project.godot").read_text(encoding="utf-8")
    found = re.search(re.escape(EXTRA_SETTING.split("/")[-1]) + r"\s*=\s*(.*)", project)
    if found:
        for path in re.findall(r'"res://([^"]+)"', found.group(1)):
            files.append(ROOT / path)
    return [f for f in files if f.exists()]


def read_redirects(files):
    redirects = {}
    for path in files:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("redirects = "):
                redirects.update(REDIRECT.findall(line))
    return redirects


def rewrite_line(line, redirects, properties):
    match = LINE.match(line)
    if not match or match.group(1) not in properties:
        return line, 0
    count = 0

    def swap(quoted):
        nonlocal count
        if quoted.group(2) in redirects:
            count += 1
            return '%s"%s"' % (quoted.group(1), redirects[quoted.group(2)])
        return quoted.group(0)

    return "%s = %s" % (match.group(1), QUOTED.sub(swap, match.group(2))), count


def main():
    parser = argparse.ArgumentParser(description="Rewrites old tag names (the declarations' redirects) in saved scenes and resources.")
    parser.add_argument("--dry-run", action="store_true", help="list what would change without writing")
    parser.add_argument("--property", action="append", default=[], help="another property name that holds tags")
    args = parser.parse_args()
    files = declaration_files()
    redirects = read_redirects(files)
    if not redirects:
        print("No redirects declared: nothing to do.")
        return 0
    properties = TAG_PROPERTIES | set(args.property)
    skip = {f.resolve() for f in files}
    changed = 0
    for path in sorted((ROOT / "assets").rglob("*")):
        if path.suffix not in (".tres", ".tscn") or path.resolve() in skip or ".godot" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")
        lines = text.split("\n")
        total = 0
        for i, line in enumerate(lines):
            lines[i], count = rewrite_line(line, redirects, properties)
            total += count
        if total:
            changed += 1
            print("%s: %d tag name%s" % (path.relative_to(ROOT).as_posix(), total, "" if total == 1 else "s"))
            if not args.dry_run:
                path.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    # Scripts: listed, not rewritten.
    for path in sorted(list((ROOT / "assets").rglob("*.gd")) + list((ROOT / "addons").rglob("*.gd"))):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for quoted in QUOTED.finditer(line):
                if quoted.group(1) == "&" and quoted.group(2) in redirects:
                    print("  old name in a script, change it by hand: %s:%d %s" % (path.relative_to(ROOT).as_posix(), number, quoted.group(2)))
    print("%s %d file%s." % ("Would change" if args.dry_run else "Changed", changed, "" if changed == 1 else "s"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
