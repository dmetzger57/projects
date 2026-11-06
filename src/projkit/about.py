"""Version shown by the CLI and web UI: VERSION plus, when running from the git repo, the commit."""
from __future__ import annotations

import functools
import subprocess
from pathlib import Path

from . import __version__

REPO = Path(__file__).resolve().parents[2]


@functools.lru_cache(maxsize=1)
def commit() -> str | None:
    """Short commit hash of the checkout this code runs from ("+" if it has uncommitted changes)."""
    if not (REPO / ".git").exists():
        return None
    try:
        run = lambda *a: subprocess.run(["git", "-C", str(REPO), *a], capture_output=True, text=True, timeout=5)
        h = run("rev-parse", "--short", "HEAD").stdout.strip()
        if not h:
            return None
        dirty = run("status", "--porcelain", "--untracked-files=no").stdout.strip()
        return h + ("+" if dirty else "")
    except (OSError, subprocess.SubprocessError):
        return None


def version_string() -> str:
    c = commit()
    return f"{__version__} ({c})" if c else __version__
