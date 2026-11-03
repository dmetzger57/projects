"""Mutating operations on projects. Shared by the CLI and the web UI."""
from __future__ import annotations

import datetime as dt
import itertools
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

from ruamel.yaml.comments import CommentedMap, CommentedSeq

from .project import FORMAT_VERSION, README, STATUSES, Project
from .workspace import BACKLOG_STEM, Workspace

RECEIPT_TAG = "receipt"
_BAD_NAME = re.compile(r'[/:\x00]')


class OpError(Exception):
    pass


def _today() -> dt.date:
    return dt.date.today()


def _check_name(name: str) -> str:
    name = name.strip()
    if not name or name.startswith(".") or _BAD_NAME.search(name):
        raise OpError(f"invalid name: {name!r}")
    return name


def _seq(p: Project, key: str) -> CommentedSeq:
    if not isinstance(p.meta.get(key), list):
        p.meta[key] = CommentedSeq()
    return p.meta[key]


# ---- project lifecycle -----------------------------------------------------
def new_project(ws: Workspace, title: str, area: str, status: str = "active") -> Project:
    title, area = _check_name(title), _check_name(area)
    if status not in STATUSES or status == "closed":
        raise OpError(f"invalid status for a new project: {status}")
    area_dir = ws.root / area
    if not area_dir.is_dir():
        raise OpError(f"area '{area}' does not exist (existing: {', '.join(ws.areas())})")
    d = area_dir / title
    # names are unique across areas: '2 - Closed' is flat and lookups are by name
    clash = [p for p in ws.projects() if p.folder_name.lower() == title.lower()]
    if d.exists() or clash:
        where = clash[0].dir.parent.name if clash else area
        raise OpError(f"a project named '{title}' already exists in '{where}'")

    tpl = ws.template()
    d.mkdir()
    try:
        # copy template folder structure / extra files (not its README or legacy pages)
        if tpl is not None:
            for c in tpl.dir.iterdir():
                if c.name.startswith(".") or c.name == README or c.suffix == ".pages":
                    continue
                (shutil.copytree if c.is_dir() else shutil.copy2)(c, d / c.name)
        for req in ("Documents", "Receipts"):
            (d / req).mkdir(exist_ok=True)

        meta = CommentedMap()
        meta["format"] = FORMAT_VERSION
        meta["title"] = title
        meta["area"] = area
        meta["status"] = status
        meta["created"] = _today()
        meta["closed"] = None
        meta["tags"] = CommentedSeq()
        meta["goals"] = CommentedSeq()
        meta["links"] = CommentedSeq()
        meta["receipts"] = CommentedSeq()
        p = Project(dir=d, meta=meta, body=_template_body(tpl))
        add_note(p, "Project created", save=False)
        p.save()
        return p
    except BaseException:
        shutil.rmtree(d, ignore_errors=True)
        raise


def _template_body(tpl: Project | None) -> str:
    """Template section headings with placeholders, Notes emptied."""
    if tpl is None or tpl.legacy or tpl.parse_error:
        return "\n## Description\n\n## Project Files\n\n## Notes\n"
    out, skip = [], False
    for ln in tpl.body.splitlines():
        if ln.startswith("## "):
            skip = ln[3:].strip().lower() == "notes"
            out.append(ln)
            continue
        if not skip:
            out.append(ln)
    return "\n".join(out).rstrip() + "\n"


def rename(ws: Workspace, p: Project, new_title: str) -> Project:
    new_title = _check_name(new_title)
    dst = p.dir.with_name(new_title)
    if dst.exists() and not dst.samefile(p.dir):
        raise OpError(f"'{dst}' already exists")
    p.meta["title"] = new_title
    p.save()
    tmp = p.dir.with_name(f".{p.dir.name}.renaming")
    p.dir.rename(tmp)
    tmp.rename(dst)
    return Project.load(dst)


def set_status(p: Project, status: str) -> None:
    if status not in STATUSES or status == "closed":
        raise OpError("use close/reopen to change closed state" if status == "closed" else f"bad status {status}")
    p.meta["status"] = status
    p.save()


def close(ws: Workspace, p: Project) -> Project:
    if ws.is_in_closed(p):
        raise OpError("project is already closed")
    dst = ws.closed_dir / p.dir.name
    if dst.exists():
        raise OpError(f"'{dst}' already exists")
    ws.closed_dir.mkdir(exist_ok=True)
    p.meta["area"] = p.area or ws.location_area(p)
    p.meta["status"] = "closed"
    p.meta["closed"] = _today()
    add_note(p, "Project closed", save=False)
    p.save()
    p.dir.rename(dst)
    return Project.load(dst)


def reopen(ws: Workspace, p: Project, area: str | None = None) -> Project:
    if not ws.is_in_closed(p):
        raise OpError("project is not closed")
    area = _check_name(area or p.area or "")
    area_dir = ws.root / area
    if not area_dir.is_dir():
        raise OpError(f"area '{area}' does not exist")
    dst = area_dir / p.dir.name
    if dst.exists():
        raise OpError(f"'{dst}' already exists")
    p.meta["area"] = area
    p.meta["status"] = "active"
    p.meta["closed"] = None
    add_note(p, "Project reopened", save=False)
    p.save()
    p.dir.rename(dst)
    return Project.load(dst)


# ---- notes -----------------------------------------------------------------
def add_note(p: Project, text: str, date: dt.date | None = None, save: bool = True) -> None:
    """Append `- text` under `### date` in `## Notes` (creating either if needed)."""
    date = date or _today()
    head = f"### {date.isoformat()}"
    bullet = "\n".join(("- " if i == 0 else "  ") + ln for i, ln in enumerate(text.strip().splitlines()))
    lines = p.body.rstrip("\n").splitlines()

    notes_i = next((i for i, l in enumerate(lines) if l.strip().lower() == "## notes"), None)
    if notes_i is None:
        lines += ["", "## Notes"]
        notes_i = len(lines) - 1
    end = next((i for i in range(notes_i + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    head_i = next((i for i in range(notes_i + 1, end) if lines[i].strip() == head), None)
    if head_i is None:
        # insert new date heading at the end of the Notes section
        while end > notes_i + 1 and not lines[end - 1].strip():
            end -= 1
        block = ([""] if end > notes_i + 1 else []) + [head, bullet]
        lines[end:end] = block
    else:
        sub_end = next((i for i in range(head_i + 1, end) if lines[i].startswith("#")), end)
        while sub_end > head_i + 1 and not lines[sub_end - 1].strip():
            sub_end -= 1
        lines[sub_end:sub_end] = [bullet]
    p.body = "\n".join(lines) + "\n"
    if save:
        p.save()


# ---- goals -----------------------------------------------------------------
def _goal_index(p: Project, ref: str) -> int:
    goals = p.goals
    if ref.isdigit():
        i = int(ref) - 1
        if 0 <= i < len(goals):
            return i
        raise OpError(f"no goal #{ref} (project has {len(goals)})")
    hits = [i for i, g in enumerate(goals) if ref.lower() in str(g.get("text", "")).lower()]
    if len(hits) != 1:
        raise OpError(f"goal reference '{ref}' matches {len(hits)} goals")
    return hits[0]


def add_goal(p: Project, text: str) -> None:
    _seq(p, "goals").append(CommentedMap(text=text.strip(), done=False))
    p.save()


def set_goal(p: Project, ref: str, done: bool) -> dict:
    g = p.meta["goals"][_goal_index(p, ref)]
    g["done"] = done
    if done:
        g["done_on"] = _today()
    elif "done_on" in g:
        del g["done_on"]
    p.save()
    return g


def remove_goal(p: Project, ref: str) -> dict:
    g = p.meta["goals"].pop(_goal_index(p, ref))
    p.save()
    return g


# ---- links -----------------------------------------------------------------
def add_link(p: Project, url: str, title: str | None = None) -> None:
    if not re.match(r"^[a-z][a-z0-9+.-]*://", url, re.I):
        raise OpError(f"not a URL: {url}")
    _seq(p, "links").append(CommentedMap(title=title or url, url=url))
    p.save()


def remove_link(p: Project, index: int) -> dict:
    links = _seq(p, "links")
    if not 0 <= index < len(links):
        raise OpError(f"no link #{index + 1}")
    l = links.pop(index)
    p.save()
    return l


# ---- body sections ---------------------------------------------------------
EDITABLE_SECTIONS = ("Description", "Project Files")


def set_section(p: Project, heading: str, text: str) -> None:
    """Replace the content of `## heading` (created before Notes if missing)."""
    if heading not in EDITABLE_SECTIONS:
        raise OpError(f"section '{heading}' is not editable")
    text = text.replace("\r\n", "\n").strip()
    if any(ln.startswith("## ") for ln in text.splitlines()):
        raise OpError("section text may not contain '## ' headings")
    lines = p.body.rstrip("\n").splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith("## ") and l[3:].strip().lower() == heading.lower()), None)
    new = [f"## {heading}"] + (text.splitlines() if text else []) + [""]
    if start is None:
        notes = next((i for i, l in enumerate(lines) if l.strip().lower() == "## notes"), len(lines))
        if notes and lines[notes - 1].strip():
            new.insert(0, "")
        lines[notes:notes] = new
    else:
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
        lines[start:end] = new if end < len(lines) else new[:-1]
    p.body = "\n".join(lines).rstrip("\n") + "\n"
    if not p.body.startswith("\n"):
        p.body = "\n" + p.body
    p.save()


# ---- receipts --------------------------------------------------------------
def remove_receipt(p: Project, index: int) -> dict:
    """Detach a receipt from the project (the file in the receipts folder is kept)."""
    rec = _seq(p, "receipts")
    if not 0 <= index < len(rec):
        raise OpError(f"no receipt #{index + 1}")
    r = rec.pop(index)
    p.save()
    return r


def tag_file(path: Path, tag: str = RECEIPT_TAG) -> None:
    """Add a Finder tag (merging with existing tags)."""
    if shutil.which("tag"):
        subprocess.run(["tag", "-a", tag, str(path)], check=True, capture_output=True)
        return
    attr = "com.apple.metadata:_kMDItemUserTags"
    r = subprocess.run(["xattr", "-px", attr, str(path)], capture_output=True, text=True)
    tags = plistlib.loads(bytes.fromhex(r.stdout.replace("\n", "").replace(" ", ""))) if r.returncode == 0 else []
    if not any(t.split("\n")[0] == tag for t in tags):
        tags.append(tag)
        data = plistlib.dumps(tags, fmt=plistlib.FMT_BINARY).hex()
        subprocess.run(["xattr", "-wx", attr, data, str(path)], check=True)


def receipt_filename(src: Path, date: dt.date, description: str | None) -> str:
    desc = _BAD_NAME.sub("-", (description or src.stem).strip())
    if re.match(r"^\d{4}-\d{2}-\d{2} ", desc):
        desc = desc[11:]
    return f"{date.isoformat()} {desc}{src.suffix.lower()}"


def add_receipt(ws: Workspace, p: Project, src: Path, amount: float | None = None,
                vendor: str | None = None, date: dt.date | None = None,
                description: str | None = None, move: bool = False, tag: bool = True) -> dict:
    """Reference a receipt. Files outside the receipts root are filed as
    <receipts>/<year>/<YYYY-MM-DD description>.<ext> (copied, or moved with move=True)."""
    src = src.expanduser().resolve()
    if not src.is_file():
        raise OpError(f"not a file: {src}")
    root = ws.receipts_root.expanduser().resolve()
    date = date or _today()
    if src.is_relative_to(root):
        target = src
    else:
        target = root / str(date.year) / receipt_filename(src, date, description or vendor)
        if target.exists():
            raise OpError(f"receipt already exists: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        (shutil.move if move else shutil.copy2)(src, target)
    rel = str(target.relative_to(root))
    if any(r.get("path") == rel for r in p.receipts):
        raise OpError(f"receipt already attached: {rel}")
    if tag:
        tag_file(target)
    entry = CommentedMap(path=rel, amount=amount, vendor=vendor, date=date)
    _seq(p, "receipts").append(entry)
    p.save()
    return entry


# ---- idea backlog ----------------------------------------------------------
def backlog_path(ws: Workspace) -> Path:
    return ws.root / f"{BACKLOG_STEM}.md"


def ideas(ws: Workspace) -> list[str]:
    f = backlog_path(ws)
    if not f.exists():
        return []
    return [l[2:].strip() for l in f.read_text(encoding="utf-8").splitlines() if l.startswith("- ")]


def _write_ideas(ws: Workspace, items: list[str]) -> None:
    f = backlog_path(ws)
    lines = f.read_text(encoding="utf-8").splitlines() if f.exists() else []
    # keep whatever precedes the first bullet (title, intro text)
    head = "\n".join(itertools.takewhile(lambda l: not l.startswith("- "), lines)).rstrip() or "# Idea Backlog"
    tmp = f.with_name(f".{f.name}.tmp")
    tmp.write_text(head + "\n\n" + "".join(f"- {i}\n" for i in items), encoding="utf-8")
    tmp.replace(f)


def add_idea(ws: Workspace, text: str) -> None:
    items = ideas(ws)
    items.append(text.strip())
    _write_ideas(ws, items)


def _idea_index(items: list[str], ref: str) -> int:
    if ref.isdigit() and 0 < int(ref) <= len(items):
        return int(ref) - 1
    hits = [i for i, t in enumerate(items) if ref.lower() in t.lower()]
    if len(hits) != 1:
        raise OpError(f"idea reference '{ref}' matches {len(hits)} ideas")
    return hits[0]


def remove_idea(ws: Workspace, ref: str) -> str:
    items = ideas(ws)
    text = items.pop(_idea_index(items, ref))
    _write_ideas(ws, items)
    return text


def promote_idea(ws: Workspace, ref: str, area: str, title: str | None = None) -> Project:
    items = ideas(ws)
    idea = items[_idea_index(items, ref)]
    p = new_project(ws, title or idea, area)
    add_note(p, f"Promoted from idea backlog: {idea}")
    remove_idea(ws, ref)
    return p
