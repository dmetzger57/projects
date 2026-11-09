"""All Open Tasks: every open task of every project that isn't closed, by project, in overview order;
a selection can be copied to Today. Same steps as ios/ProjKit/Sources/Checks/main.swift."""
import pytest
from fastapi.testclient import TestClient
from typer.testing import CliRunner

from projkit import ops
from projkit.cli import app as cli
from projkit.project import Project
from projkit.web.app import create_app
from projkit.workspace import Workspace

HX = {"HX-Request": "true"}


@pytest.fixture
def ws(tmp_path, monkeypatch):
    root = tmp_path / "Projects"
    (root / "House").mkdir(parents=True)
    (root / "Garden").mkdir()
    (root / "1 - Template").mkdir()
    monkeypatch.setattr(ops, "tag_file", lambda p, tag="receipt": None)
    w = Workspace(root, tmp_path / "Receipts")
    roof = ops.new_project(w, "Roof", "House")
    for t in ("Get quotes", "Hire roofer", "Buy shingles"):
        ops.add_task(roof, t)
    ops.set_task(roof, "Hire roofer", True)
    fence = ops.new_project(w, "Fence", "Garden")
    ops.add_task(fence, "Paint fence")
    ops.set_task(fence, "Paint", True)                      # nothing open: left out
    shed = ops.new_project(w, "Shed", "Garden")
    ops.add_task(shed, "Fix shed door")
    old = ops.new_project(w, "Old Porch", "House")
    ops.add_task(old, "Never mind")
    ops.close(w, old)                                       # closed: left out
    ops.move_area(w, "House", to=1)                         # House first on the overview
    return w


def shape(ws):
    return [(g["area"], g["project"].title, [(i, t["text"]) for i, t in g["tasks"]]) for g in ops.open_tasks(ws)]


def test_open_tasks_and_copy(ws):
    assert shape(ws) == [("House", "Roof", [(0, "Get quotes"), (1, "Buy shingles")]),
                         ("Garden", "Shed", [(0, "Fix shed door")])]
    g = ops.open_tasks(ws)
    picks = [(g[0]["project"], 1), (g[1]["project"], 0)]
    assert ops.copy_many_to_today(ws, picks) == 2
    assert [t["text"] for t in ws.today().tasks] == ["Buy shingles", "Fix shed door"]
    g = ops.open_tasks(ws)
    assert ops.copy_many_to_today(ws, [(g[0]["project"], 1), (g[0]["project"], 0)]) == 1   # one already there
    assert [t["text"] for t in ws.today().tasks] == ["Buy shingles", "Fix shed door", "Get quotes"]
    today = ws.today()
    ops.set_task(today, "Fix shed", True, ws)               # ticked in Today: no longer open in Shed
    assert shape(ws) == [("House", "Roof", [(0, "Get quotes"), (1, "Buy shingles")])]


def test_cli(ws):
    r = CliRunner().invoke(cli, ["tasks", "--root", str(ws.root), "--receipts", str(ws.receipts_root)])
    assert r.exit_code == 0, r.output
    assert r.output.index("Roof") < r.output.index("1. ☐ Get quotes") < r.output.index("Shed") < r.output.index("3. ☐ Fix shed door")
    assert "Fence" not in r.output and "Never mind" not in r.output
    r = CliRunner().invoke(cli, ["tasks", "-s", "shed", "--root", str(ws.root), "--receipts", str(ws.receipts_root)])
    assert "Fix shed door" in r.output and "Roof" not in r.output
    r = CliRunner().invoke(cli, ["tasks", "today", "3", "1", "--root", str(ws.root), "--receipts", str(ws.receipts_root)])
    assert r.exit_code == 0 and "copied 2 tasks to Today" in r.output, r.output
    assert [t["text"] for t in ws.today().tasks] == ["Fix shed door", "Get quotes"]
    r = CliRunner().invoke(cli, ["tasks", "--root", str(ws.root), "--receipts", str(ws.receipts_root)])
    assert "Get quotes  ☀ in Today" in r.output
    r = CliRunner().invoke(cli, ["tasks", "show", "2", "--root", str(ws.root), "--receipts", str(ws.receipts_root)])
    assert r.exit_code == 0 and "Roof" in r.output and "task 2 of 3" in r.output and "Buy shingles" in r.output, r.output
    r = CliRunner().invoke(cli, ["tasks", "edit", "1", "Get 3 quotes", "--root", str(ws.root), "--receipts", str(ws.receipts_root)])
    assert r.exit_code == 0 and "edited: Get 3 quotes" in r.output, r.output
    t = Project.load(ws.find("Roof")[0].dir).tasks[0]
    assert t["text"] == "Get 3 quotes" and t["id"]                  # Today link kept
    assert [x["text"] for x in ws.today().tasks] == ["Fix shed door", "Get quotes"]   # the copy keeps its own text
    r = CliRunner().invoke(cli, ["tasks", "today", "9", "--root", str(ws.root), "--receipts", str(ws.receipts_root)])
    assert r.exit_code == 1 and "no open task #9" in r.output


def test_web(ws):
    c = TestClient(create_app(ws))
    r = c.get("/tasks")
    assert r.status_code == 200 and "All Open Tasks" in r.text
    assert r.text.index("Roof") < r.text.index("Get quotes") < r.text.index("Shed") < r.text.index("Fix shed door")
    assert 'value="Roof:1"' in r.text and 'value="Roof:2"' in r.text and "Paint fence" not in r.text
    r = c.post("/tasks/today", data={"pick": ["Roof:2", "Shed:1"]}, headers=HX)
    assert r.status_code == 200 and "Copied 2 tasks" in r.text and "☀ In Today" in r.text
    assert 'value="Roof:2"' not in r.text                  # already in Today: no longer selectable
    assert [t["text"] for t in ws.today().tasks] == ["Buy shingles", "Fix shed door"]
    assert c.post("/tasks/today", data={"pick": "nope"}, headers=HX).status_code == 400
    r = c.get("/tasks/list?form=edit&pick=Roof:1")          # inline editor for that task
    assert r.status_code == 200 and 'name="text" value="Get quotes"' in r.text and 'value="Roof:1"' in r.text
    r = c.post("/tasks/edit", data={"pick": "Roof:1", "text": "Get 3 quotes"}, headers=HX)
    assert r.status_code == 200 and "Get 3 quotes" in r.text and 'name="text"' not in r.text
    assert Project.load(ws.find("Roof")[0].dir).tasks[0]["text"] == "Get 3 quotes"
    assert 'href="/p/Roof#task-1"' in r.text                  # open in its project…
    assert 'id="task-1"' in c.get("/p/Roof").text             # …where the task is the anchor
    assert c.get("/tasks/list?form=bogus&pick=Roof:1").status_code == 400


def test_web_add_note_photo_link_reminder(ws, monkeypatch):
    from projkit import reminders
    made = []
    monkeypatch.setattr(reminders, "create_reminder", lambda title, when, notes="": made.append((title, when, notes)) or "x")
    c = TestClient(create_app(ws))
    for form in ("note", "photo", "link", "remind"):
        r = c.get(f"/tasks/list?form={form}&pick=Roof:2")
        assert r.status_code == 200 and f'hx-post="/tasks/{form}"' in r.text, form
    r = c.post("/tasks/note", data={"pick": "Roof:2", "text": "Cedar, not asphalt"}, headers=HX)
    assert r.status_code == 200 and "Added a note" in r.text and "Cedar, not asphalt" in r.text
    r = c.post("/tasks/link", data={"pick": "Roof:2", "target": "https://example.com/shingles", "name": "Supplier"}, headers=HX)
    assert r.status_code == 200 and "Added a link" in r.text and ">Supplier</a>" in r.text
    r = c.post("/tasks/photo", data={"pick": "Roof:2", "note": "Sample"},
               files={"image": ("s.jpg", b"\xff\xd8\xff", "image/jpeg")}, headers=HX)
    assert r.status_code == 200 and "Added a photo" in r.text and 'alt="Sample"' in r.text
    r = c.post("/tasks/remind", data={"pick": "Roof:2", "text": "Order shingles", "when": "2026-11-20T10:00"}, headers=HX)
    assert r.status_code == 200 and "Reminder set" in r.text and "⏰ Reminder" in r.text
    assert made == [("Order shingles", "2026-11-20T10:00", "Project: Roof")]
    t = Project.load(ws.find("Roof")[0].dir).tasks[1]
    assert t["text"] == "Buy shingles" and t["notes"] == ["Cedar, not asphalt"] and t["reminder"] == "2026-11-20T10:00"
    assert [(f["name"], f["target"]) for f in t["files"]] == [("Supplier", "https://example.com/shingles")]
    assert [ph["note"] for ph in t["photos"]] == ["Sample"]
    assert c.post("/tasks/note", data={"pick": "Roof:9", "text": "x"}, headers=HX).status_code == 400


def test_cli_add_note_photo_link_reminder(ws, tmp_path, monkeypatch):
    from projkit import reminders
    made = []
    monkeypatch.setattr(reminders, "create_reminder", lambda title, when, notes="": made.append((title, when, notes)) or "x")
    run = lambda *a: CliRunner().invoke(cli, ["tasks", *a, "--root", str(ws.root), "--receipts", str(ws.receipts_root)])
    img = tmp_path / "sample.jpg"
    img.write_bytes(b"\xff\xd8\xff")
    assert run("note", "2", "Cedar, not asphalt").exit_code == 0
    assert run("photo", "2", str(img), "--note", "Sample").exit_code == 0
    assert run("link", "2", "https://example.com/shingles", "--name", "Supplier").exit_code == 0
    r = run("remind", "2", "2026-11-20 10:00", "--text", "Order shingles")
    assert r.exit_code == 0 and "reminder set" in r.output, r.output
    assert made == [("Order shingles", "2026-11-20T10:00", "Project: Roof")]
    t = Project.load(ws.find("Roof")[0].dir).tasks[1]
    assert (t["text"], t["notes"], t["reminder"]) == ("Buy shingles", ["Cedar, not asphalt"], "2026-11-20T10:00")
    assert [f["name"] for f in t["files"]] == ["Supplier"] and [ph["note"] for ph in t["photos"]] == ["Sample"]
    r = run("show", "2")
    assert "Cedar, not asphalt" in r.output and "Supplier" in r.output and "Sample" in r.output and "⏰" in r.output
    assert run("note", "9", "x").exit_code == 1


def test_web_delete_photo_and_link(ws):
    c = TestClient(create_app(ws))
    roof = ws.find("Roof")[0]
    p = Project.load(roof.dir)
    ops.add_task_file(p, "2", "https://example.com/a", "Supplier")
    ops.add_task_file(Project.load(roof.dir), "2", "https://example.com/b", "Backup")
    ph = ops.add_photo(Project.load(roof.dir), b"\xff\xd8\xff", ".jpg", "Sample", task="2")
    photo_file = ops.photo_path(Project.load(roof.dir), ph["path"])
    assert photo_file.exists()
    r = c.get("/tasks/list")
    assert 'hx-post="/tasks/photo/delete"' in r.text and 'hx-post="/tasks/link/delete"' in r.text
    r = c.post("/tasks/link/delete", data={"pick": "Roof:2", "n": "1"}, headers=HX)
    assert r.status_code == 200 and "Removed “Supplier”" in r.text and ">Backup</a>" in r.text
    r = c.post("/tasks/photo/delete", data={"pick": "Roof:2", "n": "1"}, headers=HX)
    assert r.status_code == 200 and "Deleted a photo" in r.text and 'alt="Sample"' not in r.text
    t = Project.load(roof.dir).tasks[1]
    assert [f["name"] for f in t["files"]] == ["Backup"] and t["photos"] == [] and not photo_file.exists()
    assert c.post("/tasks/photo/delete", data={"pick": "Roof:2", "n": "1"}, headers=HX).status_code == 400
    assert c.post("/tasks/link/delete", data={"pick": "Roof:2", "n": "5"}, headers=HX).status_code == 400


def test_cli_delete_photo_and_link(ws, tmp_path):
    run = lambda *a: CliRunner().invoke(cli, ["tasks", *a, "--root", str(ws.root), "--receipts", str(ws.receipts_root)])
    img = tmp_path / "sample.jpg"
    img.write_bytes(b"\xff\xd8\xff")
    assert run("photo", "2", str(img), "--note", "Sample").exit_code == 0
    assert run("link", "2", "https://example.com/shingles", "--name", "Supplier").exit_code == 0
    r = run("show", "2")
    assert "1. 📷 Sample" in r.output and "photo-rm" in r.output
    r = run("link-rm", "2", "Supplier")
    assert r.exit_code == 0 and "link removed" in r.output, r.output
    r = run("photo-rm", "2", "1")
    assert r.exit_code == 0 and "photo deleted" in r.output, r.output
    t = Project.load(ws.find("Roof")[0].dir).tasks[1]
    assert t["files"] == [] and t["photos"] == []
    assert run("photo-rm", "2", "1").exit_code == 1
