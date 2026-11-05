"""Project model: README.md front matter + body, round-trip safe."""
from __future__ import annotations

import datetime as dt
import io
import os
import re
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap

README = "README.md"
STATUSES = ("idea", "backlog", "active", "blocked", "on-hold", "closed")
FORMAT_VERSION = 1

_FM_RE = re.compile(r"\A---[ \t]*\n(.*?\n)---[ \t]*\n?", re.S)
_NOTE_HEAD = re.compile(r"^###\s+(\d{4}-\d{2}-\d{2})\s*$")
TASK_RE = re.compile(r"^- \[([ xX])\] (.+)$")   # GitHub-style task list item


def section_bounds(lines: list[str], heading: str) -> tuple[int, int] | None:
    """(index of the `## heading` line, index of the next `## ` line or len(lines))."""
    for i, ln in enumerate(lines):
        if ln.startswith("## ") and ln[3:].strip().lower() == heading.lower():
            end = next((j for j in range(i + 1, len(lines)) if lines[j].startswith("## ")), len(lines))
            return i, end
    return None


# Project Files entries: "- [Friendly name](<Documents/path/file.pdf>)" or "- [Name](https://…)"
FILE_RE = re.compile(r"^- \[([^\]]*)\]\((<[^<>]*>|[^\s()<>]+)\)\s*$")
URL_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")


def file_line_indices(lines: list[str]) -> list[int]:
    b = section_bounds(lines, "Project Files")
    return [i for i in range(b[0] + 1, b[1]) if FILE_RE.match(lines[i])] if b else []


def parse_file_line(line: str) -> dict | None:
    m = FILE_RE.match(line)
    if not m:
        return None
    target = m.group(2)
    if target.startswith("<"):
        target = target[1:-1]
    return {"name": m.group(1).strip(), "target": target,
            "kind": "url" if URL_SCHEME_RE.match(target) else "file"}


def task_line_indices(lines: list[str]) -> list[int]:
    b = section_bounds(lines, "Tasks")
    return [i for i in range(b[0] + 1, b[1]) if TASK_RE.match(lines[i])] if b else []


def task_blocks(lines: list[str]) -> list[tuple[int, int]]:
    """(start, end) line ranges of each task: the task line plus its indented detail lines."""
    b = section_bounds(lines, "Tasks")
    blocks = []
    for i in task_line_indices(lines):
        end = i + 1
        while end < b[1] and lines[end][:1] in (" ", "\t") and lines[end].strip():
            end += 1
        blocks.append((i, end))
    return blocks


def task_file_indices(lines: list[str], block: tuple[int, int]) -> list[int]:
    """Attachment lines of a task: indented Project-Files-style links among its detail lines."""
    return [j for j in range(block[0] + 1, block[1]) if FILE_RE.match(lines[j].lstrip(" \t"))]


def task_note_indices(lines: list[str], block: tuple[int, int]) -> list[int]:
    """Note lines of a task: every detail line that isn't an attachment."""
    return [j for j in range(block[0] + 1, block[1]) if not FILE_RE.match(lines[j].lstrip(" \t"))]


def parse_task_note(line: str) -> str:
    """Text of a task note line ("  - text"; a hand-written line without the bullet also counts)."""
    t = line.lstrip(" \t")
    return t[2:].strip() if t[:2] in ("- ", "* ") else t.strip()


def _yaml() -> YAML:
    y = YAML()  # round-trip mode: preserves key order and comments
    y.preserve_quotes = True
    y.indent(mapping=2, sequence=4, offset=2)
    y.width = 4096
    return y


class FrontMatterError(ValueError):
    pass


class ProjectError(Exception):
    """A user-facing problem with a project (shown as a message, never a crash)."""


def read_text_retrying(path: Path, attempts: int = 8, delay: float = 0.25) -> str:
    """Read a file that iCloud may still be downloading. macOS reports EDEADLK
    ("Resource deadlock avoided") for an evicted file being fetched; retry briefly."""
    import errno
    import time
    for i in range(attempts):
        try:
            return path.read_text(encoding="utf-8")
        except OSError as e:
            if e.errno not in (errno.EDEADLK, errno.EAGAIN, errno.EBUSY) or i == attempts - 1:
                raise
            time.sleep(delay)
    raise AssertionError("unreachable")


def split_front_matter(text: str) -> tuple[CommentedMap, str]:
    m = _FM_RE.match(text)
    if not m:
        return CommentedMap(), text
    try:
        data = _yaml().load(m.group(1)) or CommentedMap()
    except Exception as e:  # ruamel raises many types
        raise FrontMatterError(f"invalid YAML front matter: {e}") from e
    if not isinstance(data, dict):
        raise FrontMatterError("front matter is not a mapping")
    return data, text[m.end():]


def join_front_matter(meta: CommentedMap, body: str) -> str:
    buf = io.StringIO()
    _yaml().dump(meta, buf)
    return f"---\n{buf.getvalue()}---\n{body if body.startswith(chr(10)) else chr(10) + body}"


def _as_date(v) -> dt.date | None:
    if v is None or v == "":
        return None
    if isinstance(v, dt.datetime):
        return v.date()
    if isinstance(v, dt.date):
        return v
    return dt.date.fromisoformat(str(v))


@dataclass
class Note:
    date: dt.date
    text: str  # markdown under the heading, stripped


@dataclass
class Project:
    dir: Path
    meta: CommentedMap = field(default_factory=CommentedMap)
    body: str = ""
    legacy: bool = False          # no README.md yet (e.g. only Readme.pages)
    parse_error: str | None = None

    # ---- loading / saving -------------------------------------------------
    @property
    def readme(self) -> Path:
        return self.dir / README

    @classmethod
    def load(cls, d: Path) -> "Project":
        p = cls(dir=d)
        if not p.readme.exists():
            p.legacy = True
            return p
        try:
            p.meta, p.body = split_front_matter(read_text_retrying(p.readme))
        except (FrontMatterError, UnicodeDecodeError) as e:
            p.parse_error = str(e)
        except OSError as e:
            # e.g. EDEADLK while iCloud is still downloading the file: report, don't crash
            p.parse_error = f"README.md could not be read right now ({e.strerror or e}); try again shortly"
        return p

    def save(self) -> None:
        """Atomic write (temp file + rename) so iCloud never syncs a half-written file.
        Refuses to write a project whose README could not be read: its meta/body are
        empty placeholders, and saving them would wipe the real file."""
        if self.parse_error is not None:
            raise ProjectError(f"'{self.dir.name}' was not saved: {self.parse_error}")
        text = join_front_matter(self.meta, self.body)
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".README.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, self.readme)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise
        self.legacy = False

    # ---- typed accessors (read from meta; fall back to folder layout) -----
    @property
    def folder_name(self) -> str:
        return self.dir.name

    @property
    def title(self) -> str:
        return str(self.meta.get("title") or self.dir.name)

    @property
    def area(self) -> str | None:
        return self.meta.get("area")

    @property
    def status(self) -> str:
        return str(self.meta.get("status") or "active")

    @property
    def created(self) -> dt.date | None:
        return _as_date(self.meta.get("created"))

    @property
    def tags(self) -> list[str]:
        return list(self.meta.get("tags") or [])

    @property
    def goals(self) -> list[dict]:
        return list(self.meta.get("goals") or [])

    @property
    def links(self) -> list[dict]:
        return list(self.meta.get("links") or [])

    @property
    def receipts(self) -> list[dict]:
        return list(self.meta.get("receipts") or [])

    @property
    def goal_progress(self) -> tuple[int, int]:
        g = self.goals
        return sum(1 for x in g if x.get("done")), len(g)

    @property
    def total_cost(self) -> float:
        return float(sum((r.get("amount") or 0) for r in self.receipts))

    # ---- body sections ----------------------------------------------------
    def section(self, heading: str) -> str | None:
        """Text of a `## heading` section (case-insensitive), or None."""
        lines = self.body.splitlines()
        out, inside = [], False
        for ln in lines:
            if ln.startswith("## "):
                if inside:
                    break
                inside = ln[3:].strip().lower() == heading.lower()
                continue
            if inside:
                out.append(ln)
        return "\n".join(out).strip() if inside or out else None

    @property
    def tasks(self) -> list[dict]:
        """`- [ ]` / `- [x]` items in the `## Tasks` section, in order."""
        lines = self.body.splitlines()
        out = []
        for start, end in task_blocks(lines):
            m = TASK_RE.match(lines[start])
            files = [parse_file_line(lines[j].lstrip(" \t")) for j in task_file_indices(lines, (start, end))]
            notes = [parse_task_note(lines[j]) for j in task_note_indices(lines, (start, end))]
            out.append({"text": m.group(2).strip(), "done": m.group(1) != " ", "files": files, "notes": notes})
        return out

    @property
    def files(self) -> list[dict]:
        """Link entries in `## Project Files`: {name, target, kind: 'file'|'url'}."""
        lines = self.body.splitlines()
        return [parse_file_line(lines[i]) for i in file_line_indices(lines)]

    @property
    def files_other_text(self) -> str:
        """Project Files content that isn't a link entry (kept and shown as-is)."""
        lines = self.body.splitlines()
        b = section_bounds(lines, "Project Files")
        if not b:
            return ""
        keep = [lines[i] for i in range(b[0] + 1, b[1]) if not FILE_RE.match(lines[i])]
        return "\n".join(keep).strip()

    @property
    def task_progress(self) -> tuple[int, int]:
        t = self.tasks
        return sum(1 for x in t if x["done"]), len(t)

    @property
    def notes(self) -> list[Note]:
        sec = self.section("Notes")
        if not sec:
            return []
        notes: list[Note] = []
        cur_date, buf = None, []
        for ln in sec.splitlines():
            m = _NOTE_HEAD.match(ln)
            if m:
                if cur_date:
                    notes.append(Note(cur_date, "\n".join(buf).strip()))
                cur_date, buf = dt.date.fromisoformat(m.group(1)), []
            elif cur_date:
                buf.append(ln)
        if cur_date:
            notes.append(Note(cur_date, "\n".join(buf).strip()))
        return notes
