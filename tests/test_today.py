"""Today list: tasks copied from projects stay linked by a hidden id.
The exact expected strings here are mirrored in ios/ProjKit/Sources/Checks/main.swift."""
import pytest

from projkit import ops
from projkit.lint import lint_workspace
from projkit.project import Project, split_task_text
from projkit.workspace import Workspace

LINK = "\n## Tasks\n- [ ] Get quotes <!-- task:ab12cd34 -->\n- [x] Hire roofer\n\n## Notes\n"


def test_link_id_parse_and_byte_exact_ops():
    assert split_task_text("Get quotes <!-- task:ab12cd34 -->") == ("Get quotes", "ab12cd34")
    assert split_task_text("Plain") == ("Plain", None)
    t = Project(dir=None, body=LINK).tasks
    assert [(x["text"], x["id"]) for x in t] == [("Get quotes", "ab12cd34"), ("Hire roofer", None)]
    b = ops.body_edit_task(LINK, 0, "Get 3 quotes")                 # edit keeps the id
    assert b == "\n## Tasks\n- [ ] Get 3 quotes <!-- task:ab12cd34 -->\n- [x] Hire roofer\n\n## Notes\n"
    b = ops.body_set_task(b, 0, True)
    assert b.startswith("\n## Tasks\n- [x] Get 3 quotes <!-- task:ab12cd34 -->\n")
    b = ops.body_set_task_id(b, 1, "zz99yy88")
    assert "- [x] Hire roofer <!-- task:zz99yy88 -->\n" in b
    b = ops.body_add_task(b, "Call bank", "qq77ww66")
    assert b.endswith("- [x] Hire roofer <!-- task:zz99yy88 -->\n- [ ] Call bank <!-- task:qq77ww66 -->\n\n## Notes\n")
    assert len(ops.new_task_id()) == 8 and ops.new_task_id() != ops.new_task_id()


@pytest.fixture
def ws(tmp_path, monkeypatch):
    root = tmp_path / "Projects"
    (root / "House").mkdir(parents=True)
    (root / "1 - Template").mkdir()
    monkeypatch.setattr(ops, "tag_file", lambda p, tag="receipt": None)
    return Workspace(root, tmp_path / "Receipts")


def test_copy_sync_and_clear(ws):
    p = ops.new_project(ws, "Roof", "House")
    ops.add_task(p, "Get quotes")
    ops.add_task(p, "Hire roofer")
    assert ws.today() is None
    t, added = ops.copy_to_today(ws, p, "quotes")
    assert added and t["text"] == "Get quotes" and t["id"]
    assert Project.load(p.dir).tasks[0]["id"] == t["id"]
    assert ops.copy_to_today(ws, Project.load(p.dir), "1")[1] is False      # no duplicates
    with pytest.raises(ops.OpError):
        ops.copy_to_today(ws, ws.today(), "1")
    assert ops.today_ids(ws) == {t["id"]}
    assert ops.task_sources(ws)[t["id"]].title == "Roof"

    ops.set_task(ws.today(), "1", True, ws)                         # done in Today -> done in project
    assert Project.load(p.dir).tasks[0]["done"] is True
    ops.set_task(Project.load(p.dir), "1", False, ws)               # and back, from the project side
    assert ws.today().tasks[0]["done"] is False
    ops.set_task(Project.load(p.dir), "2", True, ws)                # unlinked task: Today untouched
    assert [x["done"] for x in ws.today().tasks] == [False]

    ops.add_task(ws.today(), "Call bank")                           # added directly: no link
    assert ws.today().tasks[1]["id"] is None
    ops.set_task(ws.today(), "1", True, ws)
    assert ops.clear_today_done(ws) == 1
    assert [x["text"] for x in ws.today().tasks] == ["Call bank"]
    assert Project.load(p.dir).tasks[0]["done"] is True              # original kept, still done

    p2 = Project.load(p.dir)                                        # copying a done task copies it done
    t2, _ = ops.copy_to_today(ws, p2, "1")
    assert t2["done"] is True

    assert all(x.dir != ws.today_dir for x in ws.projects())       # not an area project
    assert "0 - Today" not in ws.areas()
    assert not [i for i in lint_workspace(ws) if i.severity == "error"]
