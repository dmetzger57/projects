import datetime as dt
from pathlib import Path

import pytest

from projkit.lint import lint_workspace
from projkit.project import Project, join_front_matter, split_front_matter
from projkit.workspace import Workspace

README = """---
format: 1
title: Digital Photo Archive
area: Digital Infrastructure
status: active   # keep this comment
created: 2026-11-02
custom_key: keep me
goals:
  - text: Define updated storage structure
    done: false
  - text: Define keyword scheme
    done: true
    done_on: 2026-11-05
receipts:
  - path: 2026/scanner.pdf
    amount: 412.5
---

## Description
Organise the photo archive.

## Notes
### 2026-11-02
- Initial template format

### 2026-11-03
- Second entry
"""


def mkproj(parent: Path, name: str, readme: str | None = README, dirs=("Documents", "Receipts")) -> Path:
    d = parent / name
    d.mkdir(parents=True)
    for x in dirs:
        (d / x).mkdir()
    if readme is not None:
        (d / "README.md").write_text(readme)
    return d


@pytest.fixture
def ws(tmp_path: Path) -> Workspace:
    root, rec = tmp_path / "Projects", tmp_path / "Receipts"
    (rec / "2026").mkdir(parents=True)
    (rec / "2026" / "scanner.pdf").write_bytes(b"%PDF")
    mkproj(root, "1 - Template", readme=None)
    (root / "2 - Closed").mkdir()
    (root / "House").mkdir()
    mkproj(root / "Digital Infrastructure", "Digital Photo Archive")
    return Workspace(root, rec)


def test_roundtrip_preserves_comments_order_and_unknown_keys():
    meta, body = split_front_matter(README)
    out = join_front_matter(meta, body)
    assert out == README


def test_typed_accessors(ws):
    p = ws.find("photo")[0]
    assert p.title == "Digital Photo Archive"
    assert p.created == dt.date(2026, 11, 2)
    assert p.goal_progress == (1, 2)
    assert p.total_cost == 412.5
    assert [n.date.day for n in p.notes] == [2, 3]
    assert p.section("description") == "Organise the photo archive."


def test_save_is_atomic_and_roundtrips(ws):
    p = ws.find("photo")[0]
    p.meta["goals"][0]["done"] = True
    p.save()
    again = Project.load(p.dir)
    assert again.goal_progress == (2, 2)
    assert "# keep this comment" in again.readme.read_text()
    assert not list(p.dir.glob(".README.*"))


def test_discovery_ignores_reserved_and_hidden(ws):
    (ws.root / ".hidden").mkdir()
    assert ws.areas() == ["Digital Infrastructure", "House"]
    assert [p.folder_name for p in ws.projects()] == ["Digital Photo Archive"]


def test_clean_project_has_no_errors(ws):
    errors = [i for i in lint_workspace(ws) if i.severity == "error"]
    assert errors == []


def test_lint_detects_real_world_drift(ws):
    d = mkproj(ws.root / "Digital Infrastructure", "Web-Check Tool",
               readme=README.replace("Digital Photo Archive", "Web-Check Service")
               .replace("Define updated storage structure", "Provide a standardized project record"),
               dirs=("Documents", "Rewceipts"))
    mkproj(ws.root / "Digital Infrastructure", "Legacy One", readme=None)
    (ws.root / "Digital Infrastructure" / "Legacy One" / "Readme.pages").write_bytes(b"x")
    codes = {(i.code, i.path.parent.name if i.code != "L003" else i.path.name) for i in lint_workspace(ws)}
    assert ("L003", "Rewceipts") in codes          # misspelt folder
    assert ("L004", "Web-Check Tool") in codes     # title mismatch
    assert ("L007", "Web-Check Tool") in codes     # template goal left in
    assert ("L001", "Legacy One") in codes         # still on Pages
    assert not (d / "Receipts").exists()


def test_fixes_rename_and_create(ws):
    d = mkproj(ws.root / "House", "Roof", dirs=("documents",))
    for i in lint_workspace(ws):
        if i.fix and i.path.parent == d:
            i.fix()
    names = sorted(c.name for c in d.iterdir() if c.is_dir())
    assert names == ["Documents", "Receipts"]


def test_closed_and_area_rules(ws):
    mkproj(ws.root / "2 - Closed", "Old", readme=README.replace("status: active", "status: on-hold"))
    mkproj(ws.root / "House", "Wrong Area")
    msgs = [(i.code, i.path.parent.name) for i in lint_workspace(ws)]
    assert ("L006", "Old") in msgs
    assert ("L005", "Wrong Area") in msgs


def test_missing_receipt_reported(ws):
    p = ws.find("photo")[0]
    p.meta["receipts"].append({"path": "2026/missing.pdf"})
    p.meta["receipts"].append({"path": "../../etc/passwd"})
    p.save()
    msgs = [i.message for i in lint_workspace(ws) if i.code == "L008"]
    assert any("not found" in m for m in msgs)
    assert any("outside" in m for m in msgs)


def test_untagged_receipt_flagged_and_fixed(ws):
    from projkit.ops import file_tags
    issues = [i for i in lint_workspace(ws) if i.code == "L013"]
    assert len(issues) == 1 and issues[0].fixable      # fixture receipt has no Finder tag
    issues[0].fix()
    assert "receipt" in file_tags(ws.receipts_root / "2026" / "scanner.pdf")
    assert [i for i in lint_workspace(ws) if i.code == "L013"] == []


def test_unreadable_readme_does_not_crash(ws, monkeypatch):
    import errno
    real = Path.read_text

    def flaky(self, *a, **k):
        if self.name == "README.md" and "Digital Photo Archive" in str(self):
            raise OSError(errno.EDEADLK, "Resource deadlock avoided")
        return real(self, *a, **k)

    monkeypatch.setattr(Path, "read_text", flaky)
    p = ws.find("photo")[0]
    assert "could not be read right now" in p.parse_error
    assert any(i.code == "L009" for i in lint_workspace(ws))
