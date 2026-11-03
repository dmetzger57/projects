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
STATUSES = ("idea", "active", "on-hold", "closed")
FORMAT_VERSION = 1

_FM_RE = re.compile(r"\A---[ \t]*\n(.*?\n)---[ \t]*\n?", re.S)
_NOTE_HEAD = re.compile(r"^###\s+(\d{4}-\d{2}-\d{2})\s*$")


def _yaml() -> YAML:
    y = YAML()  # round-trip mode: preserves key order and comments
    y.preserve_quotes = True
    y.indent(mapping=2, sequence=4, offset=2)
    y.width = 4096
    return y


class FrontMatterError(ValueError):
    pass


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
            p.meta, p.body = split_front_matter(p.readme.read_text(encoding="utf-8"))
        except (FrontMatterError, UnicodeDecodeError) as e:
            p.parse_error = str(e)
        return p

    def save(self) -> None:
        """Atomic write (temp file + rename) so iCloud never syncs a half-written file."""
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
