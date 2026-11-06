#!/usr/bin/env python3
"""The app version. VERSION (repo root) is the source of truth; this copies it everywhere else.

    python3 scripts/version.py                # print the version
    python3 scripts/version.py check          # exit 1 if any file disagrees with VERSION
    python3 scripts/version.py set 1.2.0      # write 1.2.0 to VERSION and every copy

Copies: pyproject.toml, src/projkit/__init__.py, and MARKETING_VERSION in the Xcode project
(ios/make_xcodeproj.py reads VERSION itself). `make version V=1.2.0` also commits, tags and pushes.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")

# file -> (pattern whose group 2 is the version, replacement template)
COPIES = {
    ROOT / "pyproject.toml": (re.compile(r'^(version = ")([^"]*)(")', re.M), r"\g<1>{v}\g<3>"),
    ROOT / "src/projkit/__init__.py": (re.compile(r'^(__version__ = ")([^"]*)(")', re.M), r"\g<1>{v}\g<3>"),
    ROOT / "ios/Proj.xcodeproj/project.pbxproj": (re.compile(r"(MARKETING_VERSION = )([^;]*)(;)"), r"\g<1>{v}\g<3>"),
}


def current() -> str:
    return VERSION_FILE.read_text(encoding="utf-8").strip()


def mismatches(v: str) -> list[str]:
    out = []
    for f, (pat, _) in COPIES.items():
        found = [m.group(2) for m in pat.finditer(f.read_text(encoding="utf-8"))]
        if not found:
            out.append(f"{f.relative_to(ROOT)}: no version found")
        out += [f"{f.relative_to(ROOT)}: {x} (VERSION is {v})" for x in found if x != v]
    return out


def set_version(v: str) -> None:
    if not SEMVER.match(v):
        raise SystemExit(f"version must look like 1.2.3, not {v!r}")
    VERSION_FILE.write_text(v + "\n", encoding="utf-8")
    for f, (pat, repl) in COPIES.items():
        text = f.read_text(encoding="utf-8")
        new, n = pat.subn(repl.format(v=v), text)
        if not n:
            raise SystemExit(f"{f.relative_to(ROOT)}: no version to replace")
        f.write_text(new, encoding="utf-8")


def main(argv: list[str]) -> int:
    if not argv:
        print(current())
    elif argv[0] == "check":
        bad = mismatches(current())
        print("\n".join(bad) if bad else f"version {current()} is consistent")
        return 1 if bad else 0
    elif argv[0] == "set" and len(argv) == 2:
        set_version(argv[1])
        print(f"version set to {argv[1]}")
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
