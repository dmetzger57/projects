"""Today list: tasks copied from projects stay linked by a hidden id.
The exact expected strings here are mirrored in ios/ProjKit/Sources/Checks/main.swift."""
import pytest

from projkit import ops
from projkit.lint import lint_workspace
from projkit.project import Project, STATUSES, split_task_text, status_label
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

    ops.set_task(ws.today(), "1", True, ws)                         # done in Today -> done in project,
    assert [(x["text"], x["done"]) for x in Project.load(p.dir).tasks] == \
        [("Hire roofer", False), ("Get quotes", True)]              # ... and moved below the open tasks
    ops.set_task(Project.load(p.dir), "2", False, ws)               # and back, from the project side
    assert ws.today().tasks[0]["done"] is False
    assert [x["text"] for x in Project.load(p.dir).tasks] == ["Hire roofer", "Get quotes"]
    ops.set_task(Project.load(p.dir), "1", True, ws)                # unlinked task: Today untouched
    assert [x["done"] for x in ws.today().tasks] == [False]

    ops.add_task(ws.today(), "Call bank")                           # added directly: no link
    assert ws.today().tasks[1]["id"] is None
    ops.set_task(ws.today(), "1", True, ws)
    assert ops.clear_today_done(ws) == 1
    assert [x["text"] for x in ws.today().tasks] == ["Call bank"]
    assert [(x["text"], x["done"]) for x in Project.load(p.dir).tasks] == \
        [("Hire roofer", True), ("Get quotes", True)]               # original kept, still done

    p2 = Project.load(p.dir)                                        # copying a done task copies it done
    t2, _ = ops.copy_to_today(ws, p2, "1")
    assert t2["done"] is True

    assert all(x.dir != ws.today_dir for x in ws.projects())       # not an area project
    assert "0 - Today" not in ws.areas()
    assert not [i for i in lint_workspace(ws) if i.severity == "error"]


def test_done_tasks_settle_at_the_bottom(ws):
    p = ops.new_project(ws, "Garden", "House")
    for t in ("Dig", "Plant", "Water"):
        ops.add_task(p, t)
    texts = lambda: [(x["text"], x["done"]) for x in Project.load(p.dir).tasks]
    ops.set_task(Project.load(p.dir), "1", True)                     # ticked: to the bottom
    assert texts() == [("Plant", False), ("Water", False), ("Dig", True)]
    ops.set_task(Project.load(p.dir), "1", True)                     # the latest done goes last
    assert texts() == [("Water", False), ("Dig", True), ("Plant", True)]
    ops.add_task(Project.load(p.dir), "Weed")                        # new tasks go above the done ones
    assert texts() == [("Water", False), ("Weed", False), ("Dig", True), ("Plant", True)]
    ops.set_task(Project.load(p.dir), "4", False)                    # unticked: just above the done ones
    assert texts() == [("Water", False), ("Weed", False), ("Plant", False), ("Dig", True)]


def test_all_tasks_done_marks_project_completed_on_hold(ws):
    """Same steps as the Swift check "status: all tasks done → completed-on-hold"."""
    p = ops.new_project(ws, "Garden", "House")
    for t in ("Dig", "Plant"):
        ops.add_task(p, t)
    ops.set_task(Project.load(p.dir), "Dig", True, ws)
    assert Project.load(p.dir).status == "active"                   # one still open
    ops.copy_to_today(ws, Project.load(p.dir), "Plant")
    ops.set_task(ws.today(), "Plant", True, ws)                      # the last one, ticked from Today
    assert Project.load(p.dir).status == "completed-on-hold"
    assert ws.today().meta.get("status") != "completed-on-hold"     # Today itself is never completed
    ops.set_task(Project.load(p.dir), "Plant", False, ws)            # unticking leaves the status alone
    assert Project.load(p.dir).status == "completed-on-hold"
    ops.set_status(Project.load(p.dir), "active")
    ops.set_task(Project.load(p.dir), "Plant", True, ws)             # ... and ticking again sets it again
    assert Project.load(p.dir).status == "completed-on-hold"
    assert status_label("completed-on-hold") == "Completed – On Hold" and status_label("on-hold") == "On Hold"
    assert [status_label(s) for s in STATUSES] == ["Idea", "Backlog", "Active", "Blocked", "On Hold",
                                                   "Completed – On Hold", "Closed"]

    q = ops.new_project(ws, "Shed", "House")                         # closed projects stay closed
    ops.add_task(q, "Paint")
    q = ops.close(ws, Project.load(q.dir))
    ops.set_task(Project.load(q.dir), "1", True, ws)
    assert Project.load(q.dir).status == "closed"
    assert all("completed-on-hold" not in str(i) for i in lint_workspace(ws))   # a valid status
