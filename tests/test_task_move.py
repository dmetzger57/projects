import datetime as dt
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from projkit import ops
from projkit.project import Project
from projkit.web.app import create_app
from projkit.workspace import Workspace

JPEG = b"\xff\xd8\xff\xe0fake-jpeg"
HX = {"HX-Request": "true"}


@pytest.fixture
def ws(tmp_path: Path, monkeypatch) -> Workspace:
    root = tmp_path / "Projects"
    for d in ("1 - Template", "2 - Closed", "House", "Garden"):
        (root / d).mkdir(parents=True)
    (tmp_path / "Receipts").mkdir()
    monkeypatch.setattr(ops, "tag_file", lambda p, tag="receipt": None)
    w = Workspace(root, tmp_path / "Receipts")
    roof = ops.new_project(w, "Roof", "House")
    ops.add_task(roof, "Patch the leak")
    ops.add_task(roof, "Buy shingles")
    ops.add_task_note(roof, "Buy", "Ask for 30-year ones")
    ops.add_task_file(roof, "Buy", "https://example.com/shingles", "Quote")
    ops.add_photo(Project.load(roof.dir), JPEG, ".jpg", "Old ones", task="Buy",
                  now=dt.datetime(2026, 11, 6, 10, 0, 0))
    shed = ops.new_project(w, "Shed", "Garden")
    ops.add_task(shed, "Paint it")
    return w


def get(ws, name) -> Project:
    return ws.find(name)[0]


def test_move_task_to_another_project(ws):
    roof, shed = get(ws, "Roof"), get(ws, "Shed")
    photo = roof.tasks[1]["photos"][0]["path"]
    t = ops.move_task_to(ws, roof, "Buy", shed)
    assert t["text"] == "Buy shingles" and t["notes"] == ["Ask for 30-year ones"]
    assert [f["name"] for f in t["files"]] == ["Quote"] and [ph["path"] for ph in t["photos"]] == [photo]
    roof, shed = get(ws, "Roof"), get(ws, "Shed")
    assert [x["text"] for x in roof.tasks] == ["Patch the leak"]
    assert [x["text"] for x in shed.tasks] == ["Paint it", "Buy shingles"]     # added at the end
    assert (shed.dir / photo).read_bytes() == JPEG and not (roof.dir / photo).exists()
    assert "Ask for 30-year ones" not in roof.body


def test_move_keeps_today_link(ws):
    roof, shed = get(ws, "Roof"), get(ws, "Shed")
    ops.copy_to_today(ws, roof, "Patch")
    ops.move_task_to(ws, roof, "Patch", shed)
    today = ws.today()
    ops.set_task(today, "1", True, ws)                       # ticking in Today ticks the moved task
    assert get(ws, "Shed").tasks[-1]["done"] is True
    assert ops.today_sources(ws)[today.tasks[0]["id"]][1].folder_name == "Shed"


def test_move_refusals(ws):
    roof, shed = get(ws, "Roof"), get(ws, "Shed")
    with pytest.raises(ops.OpError, match="already in that project"):
        ops.move_task_to(ws, roof, "Patch", roof)
    with pytest.raises(ops.OpError, match="between projects"):
        ops.move_task_to(ws, roof, "Patch", ops.ensure_today(ws))
    with pytest.raises(ops.OpError, match="between projects"):
        ops.move_task_to(ws, roof, "Patch", ops.ensure_archive(ws))
    with pytest.raises(ops.OpError, match="no task"):
        ops.move_task_to(ws, roof, "9", shed)
    photo = roof.tasks[1]["photos"][0]["path"]               # a file of that name already in the target
    (shed.dir / "Photos").mkdir()
    (shed.dir / photo).write_bytes(b"other")
    with pytest.raises(ops.OpError, match="already exists"):
        ops.move_task_to(ws, roof, "Buy", shed)
    assert len(get(ws, "Roof").tasks) == 2 and len(get(ws, "Shed").tasks) == 1   # nothing changed


def test_move_to_closed_project(ws):
    shed = get(ws, "Shed")
    ops.close(ws, shed)
    ops.move_task_to(ws, get(ws, "Roof"), "Patch", get(ws, "Shed"))
    assert get(ws, "Shed").tasks[-1]["text"] == "Patch the leak"


def test_web_move(ws):
    c = TestClient(create_app(ws))
    r = c.get("/p/Roof/tasks?move=1", headers=HX)
    assert r.status_code == 200 and '<optgroup label="Garden">' in r.text and 'value="Shed"' in r.text
    assert 'value="Roof"' not in r.text
    r = c.post("/p/Roof/tasks/1/move-to", data={"to": "Shed"}, headers=HX)
    assert r.status_code == 200 and "Moved “Patch the leak” to" in r.text and 'href="/p/Shed"' in r.text
    assert [t["text"] for t in get(ws, "Shed").tasks] == ["Paint it", "Patch the leak"]
    assert c.post("/p/Roof/tasks/1/move-to", data={"to": "Roof"}, headers=HX).status_code == 400
