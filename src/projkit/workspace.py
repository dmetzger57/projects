"""Discovery of areas and projects under the projects root."""
from __future__ import annotations

import difflib
import os
import re
from dataclasses import dataclass
from pathlib import Path

from .project import Project

RESERVED_RE = re.compile(r"^\d+ - ")
TEMPLATE_DIR = "1 - Template"
CLOSED_DIR = "2 - Closed"
BACKLOG_STEM = "0 - Idea Backlog"
OVERVIEW_STEM = "0 - Overview"    # manual order and collapsed tiles of the Projects overview
TODAY_DIR = "0 - Today"          # the Today list: a project outside the areas
ARCHIVE_DIR = "0 - Archive"      # archived tasks from every project, also outside the areas


def default_root() -> Path:
    return Path(os.environ.get("PROJ_ROOT", "~/Documents/Projects")).expanduser()


def default_receipts_root() -> Path:
    return Path(os.environ.get("PROJ_RECEIPTS", "~/Documents/Receipts")).expanduser()


def _visible_dirs(p: Path) -> list[Path]:
    if not p.is_dir():
        return []
    return sorted(c for c in p.iterdir() if c.is_dir() and not c.name.startswith("."))


@dataclass
class Workspace:
    root: Path
    receipts_root: Path

    @classmethod
    def default(cls) -> "Workspace":
        return cls(default_root(), default_receipts_root())

    @property
    def template_dir(self) -> Path:
        return self.root / TEMPLATE_DIR

    @property
    def closed_dir(self) -> Path:
        return self.root / CLOSED_DIR

    @property
    def today_dir(self) -> Path:
        return self.root / TODAY_DIR

    def today(self) -> Project | None:
        return Project.load(self.today_dir) if (self.today_dir / "README.md").is_file() else None

    def is_today(self, p: Project) -> bool:
        return p.dir.resolve() == self.today_dir.resolve()

    @property
    def archive_dir(self) -> Path:
        return self.root / ARCHIVE_DIR

    def archive(self) -> Project | None:
        return Project.load(self.archive_dir) if (self.archive_dir / "README.md").is_file() else None

    def is_archive(self, p: Project) -> bool:
        return p.dir.resolve() == self.archive_dir.resolve()

    def area_dirs(self) -> list[Path]:
        return [d for d in _visible_dirs(self.root) if not RESERVED_RE.match(d.name)]

    def areas(self) -> list[str]:
        return [d.name for d in self.area_dirs()]

    def projects(self, include_closed: bool = True) -> list[Project]:
        dirs = [p for a in self.area_dirs() for p in _visible_dirs(a)]
        if include_closed:
            dirs += _visible_dirs(self.closed_dir)
        return [Project.load(d) for d in dirs]

    def template(self) -> Project | None:
        return Project.load(self.template_dir) if self.template_dir.is_dir() else None

    def location_area(self, p: Project) -> str | None:
        """Area implied by where the folder sits (None if in Closed)."""
        parent = p.dir.parent
        return None if parent == self.closed_dir else parent.name

    def is_in_closed(self, p: Project) -> bool:
        return p.dir.parent == self.closed_dir

    def find(self, query: str, include_closed: bool = True) -> list[Project]:
        """Exact folder/title match first, then substring, then fuzzy."""
        projs = self.projects(include_closed)
        q = query.lower()
        exact = [p for p in projs if q in (p.folder_name.lower(), p.title.lower())]
        if exact:
            return exact
        sub = [p for p in projs if q in p.folder_name.lower() or q in p.title.lower()]
        if sub:
            return sub
        names = {p.folder_name.lower(): p for p in projs}
        return [names[n] for n in difflib.get_close_matches(q, names, n=5, cutoff=0.5)]
