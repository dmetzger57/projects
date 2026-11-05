import datetime as dt
from pathlib import Path

import pytest

from projkit import migrate as mg
from projkit import ops
from projkit.lint import lint_workspace
from projkit.project import Project
from projkit.workspace import Workspace

FIX = Path(__file__).parent / "fixtures"
TODAY = dt.date.today().isoformat()


@pytest.fixture
def ws(tmp_path: Path, monkeypatch) -> Workspace:
    root, rec = tmp_path / "Projects", tmp_path / "Receipts"
    (root / "1 - Template" / "Documents").mkdir(parents=True)
    (root / "1 - Template" / "Receipts").mkdir()
    (root / "1 - Template" / "README.md").write_text(
        "---\ntitle: Project\narea: Area\nstatus: active\ngoals:\n  - text: Provide a standardized project record\n---\n"
        "\n## Description\nTBD\n\n## Project Files\n\n## Notes\n### 2026-11-02\n- Initial template format\n")
    (root / "2 - Closed").mkdir()
    (root / "House").mkdir()
    (root / "Personal").mkdir()
    rec.mkdir()
    monkeypatch.setattr(ops, "tag_file", lambda p, tag="receipt": None)
    return Workspace(root, rec)


def test_new_project_is_lint_clean(ws):
    p = ops.new_project(ws, "Roof Repair", "House")
    assert (p.dir / "Documents").is_dir() and (p.dir / "Receipts").is_dir()
    assert p.goals == [] and p.created == dt.date.today()
    assert "Initial template format" not in p.body
    assert p.notes[-1].text == "- Project created"
    errors = [i for i in lint_workspace(ws) if i.severity == "error"]
    assert errors == []


def test_new_project_rejects_bad_input(ws):
    with pytest.raises(ops.OpError):
        ops.new_project(ws, "x", "Nope")
    with pytest.raises(ops.OpError):
        ops.new_project(ws, "a/b", "House")
    ops.new_project(ws, "Dup", "House")
    with pytest.raises(ops.OpError):
        ops.new_project(ws, "Dup", "Personal")


def test_notes_append_to_same_day_and_new_day(ws):
    p = ops.new_project(ws, "N", "House")
    ops.add_note(p, "second")
    ops.add_note(p, "older", date=dt.date(2020, 1, 1))
    p = Project.load(p.dir)
    assert [n.date.isoformat() for n in p.notes] == [TODAY, "2020-01-01"]
    assert p.notes[0].text == "- Project created\n- second"


def test_note_creates_notes_section(ws):
    p = ops.new_project(ws, "N", "House")
    p.body = "\n## Description\nhello\n"
    ops.add_note(p, "multi\nline")
    p = Project.load(p.dir)
    assert p.notes[0].text == "- multi\n  line"
    assert p.section("Description") == "hello"


def test_goals(ws):
    p = ops.new_project(ws, "G", "House")
    ops.add_goal(p, "Buy shingles")
    ops.add_goal(p, "Hire roofer")
    ops.set_goal(p, "roofer", True)
    p = Project.load(p.dir)
    assert p.goal_progress == (1, 2)
    assert p.goals[1]["done_on"] == dt.date.today()
    ops.set_goal(p, "2", False)
    assert "done_on" not in Project.load(p.dir).goals[1]
    with pytest.raises(ops.OpError):
        ops.set_goal(p, "9", True)


def test_close_and_reopen_keep_area(ws):
    p = ops.new_project(ws, "C", "Personal")
    p = ops.close(ws, p)
    assert p.dir.parent == ws.closed_dir and p.status == "closed" and p.area == "Personal"
    assert [i for i in lint_workspace(ws) if i.severity == "error"] == []
    p = ops.reopen(ws, p)
    assert p.dir.parent.name == "Personal" and p.status == "active" and p.meta["closed"] is None


def test_rename(ws):
    p = ops.rename(ws, ops.new_project(ws, "Old Name", "House"), "New Name")
    assert p.dir.name == "New Name" and p.title == "New Name"
    assert not (ws.root / "House" / "Old Name").exists()


def _files_under(d):
    return sorted(str(x.relative_to(d)) for x in d.rglob("*") if x.is_file())


def test_receipt_in_receipts_root_referenced_not_copied(ws):
    src = ws.receipts_root / "2026" / "scan.PDF"
    src.parent.mkdir(parents=True)
    src.write_bytes(b"%PDF")
    before = _files_under(ws.receipts_root)
    p = ops.new_project(ws, "R", "House")
    e = ops.add_receipt(ws, p, src, amount=12.5, vendor="Lowes", date=dt.date(2026, 10, 9))
    assert e["path"] == "2026/scan.PDF"
    assert _files_under(ws.receipts_root) == before            # nothing copied
    assert ops.receipt_target(ws, e["path"]) == src.resolve()
    assert Project.load(p.dir).total_cost == 12.5
    with pytest.raises(ops.OpError):  # same file again
        ops.add_receipt(ws, p, src)
    assert [i for i in lint_workspace(ws) if i.code == "L008"] == []


def test_receipt_elsewhere_in_documents_referenced_by_path(ws, tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    src = tmp_path / "Documents" / "Finance" / "Lowes invoice.pdf"
    src.parent.mkdir(parents=True)
    src.write_bytes(b"%PDF")
    before = _files_under(ws.receipts_root)
    p = ops.new_project(ws, "R", "House")
    e = ops.add_receipt(ws, p, src, amount=3.0)
    assert e["path"] == "Documents/Finance/Lowes invoice.pdf"
    assert _files_under(ws.receipts_root) == before and src.exists()
    assert ops.receipt_target(ws, e["path"]) == src.resolve()
    assert [i for i in lint_workspace(ws) if i.code == "L008"] == []
    outside = tmp_path / "Desktop" / "x.pdf"
    outside.parent.mkdir()
    outside.write_bytes(b"%PDF")
    with pytest.raises(ops.OpError):  # not reachable from other devices
        ops.add_receipt(ws, p, outside)


def test_ideas_roundtrip_and_promote(ws):
    ops.add_idea(ws, "Backyard Sequoia tree")
    ops.add_idea(ws, "Solar panels")
    assert ops.ideas(ws) == ["Backyard Sequoia tree", "Solar panels"]
    p = ops.promote_idea(ws, "sequoia", "House")
    assert p.dir.name == "Backyard Sequoia tree"
    assert ops.ideas(ws) == ["Solar panels"]
    assert ops.backlog_path(ws).read_text().startswith("# Idea Backlog\n\n- Solar panels")


# ---- migration parser (fixtures are real Pages → Word exports) -------------
def test_migrate_parses_struck_goals_and_nested_lists():
    parsed = mg.parse(mg.read_docx(FIX / "notes_project.docx"))
    res = mg.build(parsed, "Projects Note Taking and Archiving", "Digital Infrastructure", [], None)
    assert [(g["text"], g["done"]) for g in res.meta["goals"]] == [
        ("Define storage location for project files", True),
        ("Define meta files documenting a project", True),
        ("Migrate existing projects to new workflow", False)]
    assert res.meta["created"] == dt.date(2026, 11, 2)
    assert "- Readme.pages\n  - Project description and notes" in res.body
    assert "### 2026-11-02\n- I will use iCloud" in res.body
    assert "TBD" not in res.body


def test_migrate_title_mismatch_and_pdf_link_recovery():
    parsed = mg.parse(mg.read_docx(FIX / "webcheck.docx"))
    assert parsed.readme_title == "Web-Check Service"
    res = mg.build(parsed, "Web-Check Tool", "Digital Infrastructure", ["https://example.com/wc"], None)
    assert res.meta["title"] == "Web-Check Tool"
    assert res.meta["links"][0]["url"] == "https://example.com/wc"
    assert res.meta["links"][0]["title"].startswith("Web-Check puts")
    assert any("Web-Check Service" in r for r in res.report)
    assert res.body.startswith("\n## Description\nImplement a Web-Check service")


def test_backlog_and_blocked_statuses(ws):
    p = ops.new_project(ws, "Roof Repair", "House", status="backlog")
    assert Project.load(p.dir).status == "backlog"
    ops.set_status(p, "blocked")
    assert Project.load(p.dir).status == "blocked"
    assert not [i for i in lint_workspace(ws) if i.code == "L009"]
    with pytest.raises(ops.OpError):
        ops.set_status(p, "stuck")
