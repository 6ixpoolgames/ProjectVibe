# Written by Claude (claude-opus-5-5), 2026-11-17: the MkDocs hook that keeps the wiki up to date. Before every build, including each
# rebuild while `build_wiki.py --serve` runs, it gathers the pages from the files next to the code (build_wiki.gather) and sets the
# site's menu, so a new system folder or an edited README shows without anyone running anything. build/wiki/mkdocs.yml names it.
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_wiki # noqa: E402  (the path above has to be set first)


# MkDocs calls this with the loaded settings, before anything is built.
def on_config(config, **_kwargs):
    config["nav"] = build_wiki.gather()
    return config
