"""Archive: tasks moved out of their projects, remembering where they came from.
The exact expected strings here are mirrored in ios/ProjKit/Sources/Checks/main.swift."""
import datetime as dt

import pytest
from fastapi.testclient import TestClient

from projkit import ops
from projkit.lint import lint_workspace
from projkit.project import Project, split_archived
from projkit.web.app import create_app
from projkit.workspace import Workspace

HX = {"HX-Request": "true"}
ARCH = ("\n## Tasks\n- [x] Get quotes <!-- archived:2026-11-05 from:Roof Repair --> <!-- task:ab12cd34 -->\n"
        "  - Ask about warranty\n- [ ] Order boards <!-- archived:2026-10-01 from:Raised Beds -->\n")


def test_marker_parse_and_byte_exact_ops():
    assert split_archived("Get quotes <!-- archived:2026-11-05 from:Roof Repair -->") == ("Get quotes", "2026-11-05", "Roof Repair")
    assert split_archived("Plain") == ("Plain", None, None)
    t = Project(dir=None, body=ARCH).tasks
    assert [(x["text"], x["archived"], x["from"], x["id"]) for x in t] == [
        ("Get quotes", "2026-11-05", "Roof Repair", "ab12cd34"), ("Order boards", "2026-10-01", "Raised Beds", None)]
    b = ops.body_edit_task(ARCH, 0, "Get 3 quotes")                  # edit keeps marker and id
    assert b.startswith("\n## Tasks\n- [x] Get 3 quotes <!-- archived:2026-11-05 from:Roof Repair --> <!-- task:ab12cd34 -->\n")
    b = ops.body_set_task_archived(b, 1, "2026-10-01", "Garden Beds")  # retarget
    assert "- [ ] Order boards <!-- archived:2026-10-01 from:Garden Beds -->\n" in b
    b = ops.body_set_task_archived(b, 0, None, None)                 # clear, keeping the id
    assert b.startswith("\n## Tasks\n- [x] Get 3 quotes <!-- task:ab12cd34 -->\n  - Ask about warranty\n")
    assert ops.body_task_block(ARCH, 0) == [
        "- [x] Get quotes <!-- archived:2026-11-05 from:Roof Repair --> <!-- task:ab12cd34 -->", "  - Ask about warranty"]
    b = ops.body_add_task_block("\n## Tasks\n- [ ] A\n\n## Notes\n", ["- [ ] B", "  - note"])
    assert b == "\n## Tasks\n- [ ] A\n- [ ] B\n  - note\n\n## Notes\n"
    assert ops.body_add_task_block("\n## Notes\n", ["- [ ] B", "  - n"]) == "\n## Tasks\n- [ ] B\n  - n\n\n## Notes\n"
    with pytest.raises(ops.OpError):
        ops.body_set_task_archived(ARCH, 0, "2026-11-05", "Bad --> name")


def test_filter_and_sort():
    items = list(enumerate(Project(dir=None, body=ARCH + "- [ ] Apples <!-- archived:2026-11-05 from:raised beds -->\n").tasks))
    texts = lambda xs: [t["text"] for _, t in xs]
    assert texts(ops.filter_archived(items)) == ["Apples", "Get quotes", "Order boards"]          # newest first
    assert texts(ops.filter_archived(items, sort="oldest")) == ["Order boards", "Get quotes", "Apples"]
    assert texts(ops.filter_archived(items, sort="name")) == ["Apples", "Get quotes", "Order boards"]
    assert texts(ops.filter_archived(items, sort="project")) == ["Apples", "Order boards", "Get quotes"]
    assert texts(ops.filter_archived(items, project="Raised Beds")) == ["Apples", "Order boards"]
    assert texts(ops.filter_archived(items, since=dt.date(2026, 11, 1))) == ["Apples", "Get quotes"]
    with pytest.raises(ops.OpError):
        ops.filter_archived(items, sort="bogus")


@pytest.fixture
def ws(tmp_path, monkeypatch):
    root = tmp_path / "Projects"
    (root / "House").mkdir(parents=True)
    (root / "1 - Template").mkdir()
    monkeypatch.setattr(ops, "tag_file", lambda p, tag="receipt": None)
    return Workspace(root, tmp_path / "Receipts")


def test_archive_restore_rename(ws):
    p = ops.new_project(ws, "Roof", "House")
    ops.add_task(p, "Get quotes")
    ops.add_task(p, "Hire roofer")
    ops.add_task_note(Project.load(p.dir), "1", "ask about warranty")
    t, _ = ops.copy_to_today(ws, Project.load(p.dir), "1")
    assert ws.archive() is None

    a = ops.archive_task(ws, Project.load(p.dir), "quotes", dt.date(2026, 11, 5))
    assert (a["text"], a["from"], a["archived"], a["notes"], a["id"]) == (
        "Get quotes", "Roof", "2026-11-05", ["ask about warranty"], t["id"])
    assert [x["text"] for x in Project.load(p.dir).tasks] == ["Hire roofer"]
    assert ops.archive_projects(ws) == ["Roof"]
    assert [x["text"] for _, x in ops.archived_tasks(ws, project="roof")] == ["Get quotes"]
    assert ops.archived_tasks(ws, project="Other") == []
    with pytest.raises(ops.OpError):
        ops.archive_task(ws, ws.today(), "1")
    with pytest.raises(ops.OpError):
        ops.archive_task(ws, ws.archive(), "1")

    assert ops.today_sources(ws)[t["id"]] == ("Roof (archived)", None)
    ops.set_task(ws.today(), "1", True, ws)                          # Today copy still syncs
    assert ws.archive().tasks[0]["done"] is True

    p = ops.rename(ws, Project.load(p.dir), "Roof Repair")           # rename follows into the Archive
    assert ws.archive().tasks[0]["from"] == "Roof Repair"

    r, q = ops.restore_task(ws, "1")
    assert q.folder_name == "Roof Repair" and r["text"] == "Get quotes" and r["archived"] is None
    assert [x["text"] for x in Project.load(p.dir).tasks] == ["Hire roofer", "Get quotes"]
    assert Project.load(p.dir).tasks[1]["notes"] == ["ask about warranty"]
    assert ws.archive().tasks == []

    ops.archive_task(ws, Project.load(p.dir), "1")
    p = ops.close(ws, Project.load(p.dir))                           # closed projects can still restore
    ops.restore_task(ws, "1")                                        # open: back above the done task
    assert [x["text"] for x in Project.load(p.dir).tasks] == ["Hire roofer", "Get quotes"]

    ops.archive_task(ws, Project.load(p.dir), "1")
    import shutil
    shutil.rmtree(p.dir)
    with pytest.raises(ops.OpError, match="no longer exists"):
        ops.restore_task(ws, "1")
    assert all(x.dir != ws.archive_dir for x in ws.projects())
    assert not [i for i in lint_workspace(ws) if i.severity == "error"]


def test_web_archive(ws):
    c = TestClient(create_app(ws))
    p = ops.new_project(ws, "Roof", "House")
    ops.add_task(p, "Get quotes")
    ops.add_task(p, "Hire roofer")
    r = c.post("/p/Roof/tasks/1/archive", headers=HX)
    assert r.status_code == 200 and "Get quotes" in r.text and "Archived (1)" in r.text
    r = c.get("/archive")
    assert r.status_code == 200 and "Get quotes" in r.text and 'href="/p/Roof"' in r.text
    assert "Get quotes" not in c.get("/archive?project=Nope").text
    assert "Get quotes" in c.get("/archive?project=roof&since=7&sort=name").text
    assert "Get quotes" in c.get("/p/0%20-%20Archive").text
    r = c.post("/p/Roof/archived/1/restore", headers=HX)
    assert r.status_code == 200 and "Archived (" not in r.text
    assert [x["text"] for x in Project.load(p.dir).tasks] == ["Hire roofer", "Get quotes"]
    c.post("/p/Roof/tasks/1/archive", headers=HX)
    assert c.post("/archive/1/restore", headers=HX).headers["HX-Refresh"] == "true"
    c.post("/p/Roof/tasks/1/archive", headers=HX)
    c.post("/archive/1/delete", headers=HX)
    assert ws.archive().tasks == []
    ops.add_task(ops.ensure_today(ws), "Call bank")
    assert c.post("/p/0%20-%20Today/tasks/1/archive", headers=HX).status_code == 400
