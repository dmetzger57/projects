"""Reminders: a task records the Apple Reminder scheduled for it.
The exact expected strings here are mirrored in ios/ProjKit/Sources/Checks/main.swift."""
import pytest
from fastapi.testclient import TestClient

from projkit import ops, reminders
from projkit.project import Project, split_reminder
from projkit.web.app import create_app
from projkit.workspace import Workspace

HX = {"HX-Request": "true"}
BODY = "\n## Tasks\n- [ ] Call plumber <!-- task:ab12cd34 -->\n  - Ask about warranty\n- [x] Order boards\n"


def test_marker_parse_and_byte_exact_ops():
    assert split_reminder("Call <!-- reminder:2026-11-10T09:00 -->") == ("Call", "2026-11-10T09:00")
    assert split_reminder("Plain") == ("Plain", None)
    b = ops.body_set_task_reminder(BODY, 0, "2026-11-10T09:00")
    assert b == ("\n## Tasks\n- [ ] Call plumber <!-- reminder:2026-11-10T09:00 --> <!-- task:ab12cd34 -->\n"
                 "  - Ask about warranty\n- [x] Order boards\n")
    t = Project(dir=None, body=b).tasks
    assert [(x["text"], x["reminder"], x["id"]) for x in t] == [
        ("Call plumber", "2026-11-10T09:00", "ab12cd34"), ("Order boards", None, None)]
    b = ops.body_edit_task(b, 0, "Call the plumber")                  # edit keeps reminder and id
    assert b.startswith("\n## Tasks\n- [ ] Call the plumber <!-- reminder:2026-11-10T09:00 --> <!-- task:ab12cd34 -->\n")
    b = ops.body_set_task_reminder(b, 0, "2026-11-12T14:30")          # rescheduling replaces it
    assert "- [ ] Call the plumber <!-- reminder:2026-11-12T14:30 --> <!-- task:ab12cd34 -->\n" in b
    b = ops.body_set_task_archived(b, 0, "2026-11-13", "House")       # archive marker goes after it
    assert ("- [ ] Call the plumber <!-- reminder:2026-11-12T14:30 --> <!-- archived:2026-11-13 from:House -->"
            " <!-- task:ab12cd34 -->\n") in b
    assert Project(dir=None, body=b).tasks[0]["reminder"] == "2026-11-12T14:30"
    b = ops.body_set_task_archived(b, 0, None, None)
    b = ops.body_set_task_reminder(b, 0, None)                         # clear, keeping the id
    assert b.startswith("\n## Tasks\n- [ ] Call the plumber <!-- task:ab12cd34 -->\n  - Ask about warranty\n")
    with pytest.raises(ops.OpError):
        ops.body_set_task_reminder(BODY, 0, "tomorrow")


def test_parse_when_and_label():
    assert reminders.parse_when("2026-11-10 14:05") == "2026-11-10T14:05"
    assert reminders.parse_when("2026-11-10T14:05") == "2026-11-10T14:05"
    assert reminders.parse_when("2026-11-10") == "2026-11-10T09:00"
    with pytest.raises(reminders.ReminderError):
        reminders.parse_when("next week")
    assert reminders.reminder_label("2030-01-02T08:15") == "Wed Jan 2 2030, 08:15"


@pytest.fixture
def ws(tmp_path, monkeypatch):
    root = tmp_path / "Projects"
    (root / "House").mkdir(parents=True)
    (root / "1 - Template").mkdir()
    made = []
    monkeypatch.setattr(reminders, "create_reminder", lambda title, when, notes="": made.append((title, when, notes)) or "x-id")
    w = Workspace(root, tmp_path / "Receipts")
    w.made = made
    return w


def test_schedule_and_web(ws):
    p = ops.new_project(ws, "Roof", "House")
    ops.add_task(p, "Get quotes")
    t = reminders.schedule_task_reminder(p, "1", "2026-11-10 09:30")
    assert t["reminder"] == "2026-11-10T09:30" and t["text"] == "Get quotes"
    assert ws.made[-1] == ("Get quotes", "2026-11-10T09:30", "Project: Roof")
    c = TestClient(create_app(ws))
    r = c.get("/p/Roof/tasks?remind=1")
    assert r.status_code == 200 and 'type="datetime-local"' in r.text and 'value="2026-11-10T09:30"' in r.text
    r = c.post("/p/Roof/tasks/1/remind", data={"text": "Phone roofers", "when": "2026-11-11T16:00"}, headers=HX)
    assert r.status_code == 200 and "⏰ Reminder" in r.text
    assert ws.made[-1] == ("Phone roofers", "2026-11-11T16:00", "Project: Roof")
    assert Project.load(p.dir).tasks[0]["reminder"] == "2026-11-11T16:00"
    r = c.post("/p/Roof/tasks/1/reminder/clear", headers=HX)
    assert r.status_code == 200 and Project.load(p.dir).tasks[0]["reminder"] is None
    assert c.post("/p/Roof/tasks/1/remind", data={"when": "soon"}, headers=HX).status_code == 400
