"""One-time migration of Readme.pages → README.md (and the idea backlog).

Pages has no readable on-disk format, so we drive Pages via AppleScript:
  * Word export  → structure, list nesting, strikethrough (= goal done)
  * PDF export   → hyperlink URLs (the Word export drops them)
"""
from __future__ import annotations

import datetime as dt
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from ruamel.yaml.comments import CommentedMap, CommentedSeq

from .project import FORMAT_VERSION, Project

EXPORT_SCRIPT = """
on run argv
  set src to POSIX file (item 1 of argv)
  set dst to POSIX file (item 2 of argv)
  set fmt to item 3 of argv
  tell application "Pages"
    set d to open src
    if d is missing value then
      delay 1
      set d to front document
    end if
    if fmt is "docx" then
      export d to dst as Microsoft Word
    else
      export d to dst as PDF
    end if
    close d saving no
  end tell
end run
"""

KNOWN_SECTIONS = {"description": "Description", "goals": "Goals", "project files": "Project Files",
                  "files": "Project Files", "links": "Links", "notes": "Notes"}
SECTION_ORDER = ["Description", "Project Files", "Notes"]  # goals/links go to front matter
PLACEHOLDERS = {"tbd", ""}
DATE_RE = re.compile(r"^(?:[A-Z][a-z]+day,\s+)?([A-Z][a-z]+ \d{1,2}, \d{4})$")
URL_RE = re.compile(r"https?://\S+")


def parse_long_date(s: str) -> dt.date | None:
    m = DATE_RE.match(s.strip())
    if not m:
        return None
    try:
        return dt.datetime.strptime(m.group(1), "%B %d, %Y").date()
    except ValueError:
        return None


def pages_export(src: Path, dst: Path, fmt: str) -> None:
    r = subprocess.run(["osascript", "-", str(src), str(dst), fmt], input=EXPORT_SCRIPT,
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0 or not dst.exists():
        raise RuntimeError(f"Pages export of {src.name} as {fmt} failed: {r.stderr.strip()}")


# ---------------------------------------------------------------------------
@dataclass
class Para:
    text: str
    md: str
    style: str
    ilvl: int | None
    strike: bool
    links: list[tuple[str, str]] = field(default_factory=list)


def read_docx(path: Path) -> list[Para]:
    import docx
    from docx.text.hyperlink import Hyperlink

    out: list[Para] = []
    for p in docx.Document(str(path)).paragraphs:
        pPr = p._p.pPr
        ilvl = None
        if pPr is not None and pPr.numPr is not None:
            ilvl = pPr.numPr.ilvl.val if pPr.numPr.ilvl is not None else 0
        md_parts, links, struck = [], [], []
        for item in p.iter_inner_content():
            if isinstance(item, Hyperlink):
                if item.address:
                    links.append((item.text, item.address))
                    md_parts.append(f"[{item.text}]({item.address})")
                else:
                    md_parts.append(item.text)
            else:
                t = item.text
                if t.strip():
                    struck.append(bool(item.font.strike))
                md_parts.append(f"~~{t}~~" if item.font.strike and t.strip() else t)
        out.append(Para(p.text.strip(), "".join(md_parts).strip(), p.style.name if p.style else "",
                        ilvl, bool(struck) and all(struck), links))
    return out


def read_pdf_uris(path: Path) -> list[str]:
    from pypdf import PdfReader

    uris: list[str] = []
    for page in PdfReader(str(path)).pages:
        for a in page.get("/Annots") or []:
            uri = (a.get_object().get("/A") or {}).get("/URI")
            if uri and str(uri) not in uris:
                uris.append(str(uri))
    return uris


# ---------------------------------------------------------------------------
@dataclass
class Parsed:
    readme_title: str | None
    readme_area: str | None
    created: dt.date | None
    sections: dict[str, list[Para]]


def parse(paras: list[Para]) -> Parsed:
    title = area = None
    created = None
    sections: dict[str, list[Para]] = {"Description": []}
    current = "Description"
    for p in paras:
        if p.style.startswith("Header"):
            created = created or parse_long_date(p.text)
            continue
        if title is None and "->" in p.text and p.ilvl is None:
            area, _, title = (s.strip() for s in p.text.partition("->"))
            continue
        key = p.text.lower().rstrip(":")
        if p.ilvl is None and key in KNOWN_SECTIONS:
            current = KNOWN_SECTIONS[key]
            sections.setdefault(current, [])
            continue
        if not p.text:
            continue
        sections.setdefault(current, []).append(p)
    return Parsed(title, area, created, sections)


def render_block(paras: list[Para], dated: bool = False) -> str:
    lines: list[str] = []
    prev_list = None
    for p in paras:
        if p.text.lower() in PLACEHOLDERS:
            continue
        d = parse_long_date(p.text) if dated else None
        if d:
            if lines:
                lines.append("")
            lines.append(f"### {d.isoformat()}")
            prev_list = None
            continue
        is_list = p.ilvl is not None
        if lines and (not is_list or prev_list is False):
            lines.append("")
        lines.append(f"{'  ' * p.ilvl}- {p.md}" if is_list else p.md)
        prev_list = is_list
    return "\n".join(lines).strip()


@dataclass
class Result:
    meta: CommentedMap
    body: str
    report: list[str]


def build(parsed: Parsed, folder: str, area: str, pdf_uris: list[str], fallback_created: dt.date | None) -> Result:
    report: list[str] = []
    goals = CommentedSeq()
    for p in parsed.sections.get("Goals", []):
        if p.text.lower() in PLACEHOLDERS:
            continue
        g = CommentedMap(text=p.text, done=p.strike)
        goals.append(g)

    links = CommentedSeq()
    unresolved: list[str] = []
    for p in parsed.sections.get("Links", []):
        if p.text.lower() in PLACEHOLDERS:
            continue
        if p.links:
            links.extend(CommentedMap(title=t, url=u) for t, u in p.links)
        elif m := URL_RE.search(p.text):
            links.append(CommentedMap(title=p.text.replace(m.group(0), "").strip() or m.group(0), url=m.group(0)))
        else:
            links.append(CommentedMap(title=p.text, url=None))
            unresolved.append(p.text)
    known = {l["url"] for l in links if l["url"]}
    spare = [u for u in pdf_uris if u not in known]
    for l in links:
        if l["url"] is None and spare:
            l["url"] = spare.pop(0)
    for l in links:
        if l["url"] is None:
            report.append(f"link without URL kept: {l['title']!r}")
    for u in spare:
        if not any(u in p.md for ps in parsed.sections.values() for p in ps):
            links.append(CommentedMap(title=u, url=u))
            report.append(f"link recovered from PDF: {u}")

    if parsed.readme_title and parsed.readme_title != folder:
        report.append(f"README title was {parsed.readme_title!r}; using folder name {folder!r}")

    created = parsed.created or fallback_created
    meta = CommentedMap()
    meta["format"] = FORMAT_VERSION
    meta["title"] = folder
    meta["area"] = area
    meta["status"] = "active"
    meta["created"] = created
    meta["closed"] = None
    meta["tags"] = CommentedSeq()
    meta["goals"] = goals
    meta["links"] = links
    meta["receipts"] = CommentedSeq()
    meta["migrated_from"] = "Readme.pages"

    parts = []
    for name in SECTION_ORDER + [s for s in parsed.sections if s not in SECTION_ORDER + ["Goals", "Links"]]:
        text = render_block(parsed.sections.get(name, []), dated=(name == "Notes"))
        parts.append(f"## {name}\n{text}\n" if text else f"## {name}\n")
    done = sum(1 for g in goals if g["done"])
    report.append(f"{len(goals)} goal(s), {done} done; {len(links)} link(s)")
    return Result(meta, "\n" + "\n".join(parts), report)


# ---------------------------------------------------------------------------
def legacy_readme(d: Path) -> Path | None:
    for c in sorted(d.glob("*.pages")):
        if c.name.lower() == "readme.pages":
            return c
    return None


def convert(pages: Path, folder: str, area: str) -> Result:
    birth = dt.date.fromtimestamp(pages.stat().st_birthtime) if hasattr(pages.stat(), "st_birthtime") else None
    with tempfile.TemporaryDirectory() as td:
        docx_path, pdf_path = Path(td) / "r.docx", Path(td) / "r.pdf"
        pages_export(pages, docx_path, "docx")
        pages_export(pages, pdf_path, "pdf")
        return build(parse(read_docx(docx_path)), folder, area, read_pdf_uris(pdf_path), birth)


def write_project(d: Path, res: Result, pages: Path) -> Path:
    p = Project(dir=d, meta=res.meta, body=res.body)
    p.save()
    legacy = pages.with_name("Readme.legacy.pages")
    pages.rename(legacy)
    return legacy


def convert_backlog(pages: Path) -> str:
    with tempfile.TemporaryDirectory() as td:
        docx_path = Path(td) / "b.docx"
        pages_export(pages, docx_path, "docx")
        paras = read_docx(docx_path)
    items = [p.md for p in paras if p.ilvl is not None and p.text.lower() not in PLACEHOLDERS]
    return "# Idea Backlog\n\n" + "".join(f"- {i}\n" for i in items)
