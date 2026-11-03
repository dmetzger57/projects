"""Structural checks for the projects tree. Each Issue may carry a safe auto-fix."""
from __future__ import annotations

import datetime as dt
import difflib
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .ops import RECEIPT_TAG, file_tags, tag_file
from .project import README, STATUSES, Project
from .workspace import Workspace

REQUIRED_DIRS = ("Documents", "Receipts")
SF_DATALESS = 0x40000000  # macOS: file content evicted to iCloud
PLACEHOLDERS = {"tbd", "provide a standardized project record"}


@dataclass
class Issue:
    code: str
    severity: str          # error | warn | info
    path: Path
    message: str
    fix: Callable[[], str] | None = None   # returns description of what it did

    @property
    def fixable(self) -> bool:
        return self.fix is not None


def _is_dataless(p: Path) -> bool:
    try:
        return bool(getattr(os.lstat(p), "st_flags", 0) & SF_DATALESS)
    except OSError:
        return False


def _mkdir_fix(path: Path) -> Callable[[], str]:
    def f() -> str:
        path.mkdir(exist_ok=False)
        return f"created {path.name}/"
    return f


def _rename_fix(src: Path, dst: Path) -> Callable[[], str]:
    def f() -> str:
        if dst.exists() and not dst.samefile(src):
            raise FileExistsError(dst)
        # two-step rename so case-only changes work on case-insensitive APFS
        tmp = src.with_name(f".{src.name}.renaming")
        src.rename(tmp)
        tmp.rename(dst)
        return f"renamed {src.name} -> {dst.name}"
    return f


def _check_layout(p: Project) -> list[Issue]:
    issues: list[Issue] = []
    children = {c.name: c for c in p.dir.iterdir() if not c.name.startswith(".")}
    expected = set(REQUIRED_DIRS) | {README}
    misspelled: dict[str, Path] = {}  # required name -> existing near-miss folder
    for name, c in children.items():
        if c.is_symlink():
            issues.append(Issue("L010", "warn", c, "symlink in project; symlinks do not sync via iCloud"))
        if name in expected or not c.is_dir():
            continue
        close = difflib.get_close_matches(name, REQUIRED_DIRS, n=1, cutoff=0.75) or \
            [r for r in REQUIRED_DIRS if r.lower() == name.lower()]
        if close and close[0] not in children and close[0] not in misspelled:
            misspelled[close[0]] = c
    for req in REQUIRED_DIRS:
        if req in children:
            continue
        if req in misspelled:
            c = misspelled[req]
            issues.append(Issue("L003", "error", c, f"folder '{c.name}' looks like a misspelling of '{req}'",
                                _rename_fix(c, p.dir / req)))
        else:
            issues.append(Issue("L002", "error", p.dir / req, f"missing {req}/ folder", _mkdir_fix(p.dir / req)))
    return issues


def _check_meta(ws: Workspace, p: Project, template_goals: set[str]) -> list[Issue]:
    issues: list[Issue] = []
    m, rd = p.meta, p.readme

    def add(code, sev, msg):
        issues.append(Issue(code, sev, rd, msg))

    if not m:
        add("L009", "error", "README.md has no YAML front matter")
        return issues
    for key in ("title", "area", "status"):
        if not m.get(key):
            add("L009", "error", f"front matter missing '{key}'")
    if p.status not in STATUSES:
        add("L009", "error", f"unknown status '{p.status}' (expected one of {', '.join(STATUSES)})")
    for key in ("created", "closed"):
        v = m.get(key)
        if v not in (None, "") and not isinstance(v, dt.date):
            try:
                dt.date.fromisoformat(str(v))
            except ValueError:
                add("L009", "error", f"'{key}' is not an ISO date: {v!r}")
    for i, g in enumerate(p.goals):
        if not isinstance(g, dict) or not g.get("text"):
            add("L009", "error", f"goal #{i + 1} has no text")

    if p.title != p.folder_name:
        add("L004", "warn", f"title '{p.title}' differs from folder name '{p.folder_name}'")

    loc = ws.location_area(p)
    in_closed = ws.is_in_closed(p)
    if loc and p.area and p.area != loc:
        add("L005", "error", f"area '{p.area}' but folder is under '{loc}'")
    if p.area and p.area not in ws.areas():
        add("L005", "warn", f"area '{p.area}' has no folder at the top level")
    if p.status == "closed" and not in_closed:
        add("L006", "error", "status is closed but project is not in '2 - Closed'")
    if in_closed and p.status != "closed":
        add("L006", "error", f"project is in '2 - Closed' but status is '{p.status}'")
    if p.status == "closed" and not m.get("closed"):
        add("L006", "warn", "closed project has no 'closed' date")

    leftovers = [g.get("text") for g in p.goals
                 if isinstance(g, dict) and str(g.get("text", "")).strip().lower() in PLACEHOLDERS | template_goals]
    desc = (p.section("Description") or "").strip().lower()
    if leftovers:
        add("L007", "warn", f"template placeholder goal(s) still present: {leftovers}")
    if desc in PLACEHOLDERS or not desc:
        add("L007", "info", "Description is empty or TBD")

    rroot = ws.receipts_root.resolve()
    for r in p.receipts:
        rel = str(r.get("path", ""))
        target = (ws.receipts_root / rel).expanduser()
        if not rel:
            add("L008", "error", "receipt entry without path")
        elif not target.resolve().is_relative_to(rroot):
            add("L008", "error", f"receipt outside {ws.receipts_root}: {rel}")
        elif not target.exists():
            add("L008", "error", f"receipt not found: {rel}")
        elif _is_dataless(target):
            add("L011", "info", f"receipt not downloaded from iCloud: {rel}")
        else:
            tags = file_tags(target)
            if tags is not None and RECEIPT_TAG not in tags:
                # e.g. filed from the iPhone app, which cannot set Finder tags
                issues.append(Issue("L013", "warn", target, f"receipt missing Finder tag '{RECEIPT_TAG}': {rel}",
                                    _tag_fix(target)))
    return issues


def _tag_fix(path: Path) -> Callable[[], str]:
    def f() -> str:
        tag_file(path)
        return f"tagged {path.name} '{RECEIPT_TAG}'"
    return f


def lint_project(ws: Workspace, p: Project, template_goals: set[str] | None = None) -> list[Issue]:
    issues = _check_layout(p)
    if p.legacy:
        pages = [c.name for c in p.dir.glob("*.pages")]
        hint = f" (found {', '.join(pages)} — run `proj migrate`)" if pages else ""
        issues.append(Issue("L001", "error", p.readme, f"missing README.md{hint}"))
        return issues
    if p.parse_error:
        issues.append(Issue("L009", "error", p.readme, p.parse_error))
        return issues
    if _is_dataless(p.readme):
        issues.append(Issue("L011", "info", p.readme, "README.md not downloaded from iCloud"))
    return issues + _check_meta(ws, p, template_goals or set())


def lint_workspace(ws: Workspace) -> list[Issue]:
    issues: list[Issue] = []
    if not ws.root.is_dir():
        return [Issue("L000", "error", ws.root, "projects root does not exist")]
    if not ws.receipts_root.is_dir():
        issues.append(Issue("L000", "warn", ws.receipts_root, "receipts root does not exist"))
    tpl = ws.template()
    tpl_goals: set[str] = set()
    if tpl is None:
        issues.append(Issue("L000", "warn", ws.template_dir, "template folder missing"))
    elif not tpl.legacy and not tpl.parse_error:
        tpl_goals = {str(g.get("text", "")).strip().lower() for g in tpl.goals if isinstance(g, dict)}
    projects = ws.projects()
    seen: dict[str, Path] = {}
    for p in projects:
        key = p.folder_name.lower()
        if key in seen:
            issues.append(Issue("L012", "error", p.dir,
                                f"project name also used in '{seen[key].parent.name}' (names must be unique)"))
        seen.setdefault(key, p.dir)
        issues += lint_project(ws, p, tpl_goals)
    return issues
