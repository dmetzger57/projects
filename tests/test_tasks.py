"""Tasks: `## Tasks` section with GitHub task-list items.
The exact expected strings here are mirrored in ios/ProjKit/Sources/Checks/main.swift."""
import pytest

from projkit import ops
from projkit.project import Project

BODY = "\n## Description\nx\n\n## Project Files\n\n## Notes\n### 2026-11-02\n- n\n"


def test_add_creates_section_before_notes_then_appends():
    b = ops.body_add_task(BODY, "Order scanner")
    assert b == "\n## Description\nx\n\n## Project Files\n\n## Tasks\n- [ ] Order scanner\n\n## Notes\n### 2026-11-02\n- n\n"
    b = ops.body_add_task(b, "Pick storage\nlocation  ")
    assert "## Tasks\n- [ ] Order scanner\n- [ ] Pick storage location\n\n## Notes" in b


def test_add_without_notes_and_into_section_with_intro_text():
    assert ops.body_add_task("\n## Description\nx\n", "a") == "\n## Description\nx\n\n## Tasks\n- [ ] a\n"
    b = "\n## Tasks\nThings to do:\n\n## Notes\n"
    assert ops.body_add_task(b, "a") == "\n## Tasks\nThings to do:\n- [ ] a\n\n## Notes\n"


def test_toggle_edit_remove_keep_other_lines():
    b = "\n## Tasks\n- [ ] one\n  indented detail\n- [X] two\n* [ ] not a task\n\n## Notes\n"
    p = Project(dir=None, body=b)
    assert p.tasks == [{"text": "one", "done": False, "files": [], "notes": ["indented detail"], "id": None}, {"text": "two", "done": True, "files": [], "notes": [], "id": None}]
    b = ops.body_set_task(b, 0, True)
    b = ops.body_set_task(b, 1, False)
    assert b == "\n## Tasks\n- [x] one\n  indented detail\n- [ ] two\n* [ ] not a task\n\n## Notes\n"
    b = ops.body_edit_task(b, 0, "one, renamed")
    assert "- [x] one, renamed\n" in b
    b = ops.body_remove_task(b, 1)
    assert b == "\n## Tasks\n- [x] one, renamed\n  indented detail\n* [ ] not a task\n\n## Notes\n"
    with pytest.raises(ops.OpError):
        ops.body_remove_task(b, 5)
    with pytest.raises(ops.OpError):
        ops.body_edit_task(b, 0, "   ")


def test_project_level_ops(tmp_path):
    d = tmp_path / "P"
    d.mkdir()
    p = Project(dir=d, body=BODY)
    p.meta["title"] = "P"
    p.save()
    ops.add_task(p, "Buy shingles")
    ops.add_task(p, "Hire roofer")
    assert ops.set_task(p, "roofer", True) == {"text": "Hire roofer", "done": True, "files": [], "notes": [], "id": None}
    ops.edit_task(p, "1", "Buy cedar shingles")
    q = Project.load(d)
    assert q.tasks == [{"text": "Buy cedar shingles", "done": False, "files": [], "notes": [], "id": None}, {"text": "Hire roofer", "done": True, "files": [], "notes": [], "id": None}]
    assert q.task_progress == (1, 2)
    ops.remove_task(q, "cedar")
    assert Project.load(d).tasks == [{"text": "Hire roofer", "done": True, "files": [], "notes": [], "id": None}]
    assert Project.load(d).notes[0].text == "- n"          # notes untouched


MOVE = "\n## Tasks\nIntro\n- [ ] a\n  a detail\n- [x] b\n- [ ] c\n  c1\n  c2\n\n## Notes\n"


def test_move_carries_detail_lines():
    assert ops.body_move_task(MOVE, 2, 0) == "\n## Tasks\nIntro\n- [ ] c\n  c1\n  c2\n- [ ] a\n  a detail\n- [x] b\n\n## Notes\n"
    assert ops.body_move_task(MOVE, 0, 2) == "\n## Tasks\nIntro\n- [x] b\n- [ ] c\n  c1\n  c2\n- [ ] a\n  a detail\n\n## Notes\n"
    assert ops.body_move_task(MOVE, 0, 1) == "\n## Tasks\nIntro\n- [x] b\n- [ ] a\n  a detail\n- [ ] c\n  c1\n  c2\n\n## Notes\n"
    assert ops.body_move_task(MOVE, 1, 1) == MOVE
    assert ops.body_move_task(MOVE, 1, 99) == ops.body_move_task(MOVE, 1, 2)     # clamped
    with pytest.raises(ops.OpError):
        ops.body_move_task(MOVE, 3, 0)


def test_remove_takes_detail_lines():
    assert ops.body_remove_task(MOVE, 2) == "\n## Tasks\nIntro\n- [ ] a\n  a detail\n- [x] b\n\n## Notes\n"
    assert ops.body_remove_task(MOVE, 0) == "\n## Tasks\nIntro\n- [x] b\n- [ ] c\n  c1\n  c2\n\n## Notes\n"


def test_move_task_project_level(tmp_path):
    d = tmp_path / "P"
    d.mkdir()
    p = Project(dir=d, body=BODY)
    p.meta["title"] = "P"
    p.save()
    for t in ("one", "two", "three"):
        ops.add_task(p, t)
    ops.move_task(p, "three", 1)
    assert [t["text"] for t in Project.load(d).tasks] == ["three", "one", "two"]


# ---- task attachments (indented links under a task) -------------------------
ATT = "\n## Tasks\n- [ ] A\n  note\n- [x] B\n\n## Notes\n"


def test_attachments_add_edit_remove_byte_exact():
    b = ops.body_add_task_file(ATT, 0, "Quote", "Documents/Q/x y.pdf")
    b = ops.body_add_task_file(b, 0, None, "https://epson.com/ff")
    assert b == ("\n## Tasks\n- [ ] A\n  note\n  - [Quote](<Documents/Q/x y.pdf>)\n"
                 "  - [epson.com](https://epson.com/ff)\n- [x] B\n\n## Notes\n")
    assert Project(dir=None, body=b).tasks[0]["files"] == [
        {"name": "Quote", "target": "Documents/Q/x y.pdf", "kind": "file"},
        {"name": "epson.com", "target": "https://epson.com/ff", "kind": "url"}]
    b = ops.body_add_task(b, "C")                     # appended after the last task block
    assert b.endswith("- [x] B\n- [ ] C\n\n## Notes\n")
    b = ops.body_add_task_file(b, 1, "Manual", "Documents/M.pdf")
    assert "- [x] B\n  - [Manual](<Documents/M.pdf>)\n- [ ] C\n" in b
    b = ops.body_edit_task_file(b, 0, 1, "Epson [site]", None)
    assert "  - [Epson (site)](https://epson.com/ff)\n" in b
    b = ops.body_remove_task_file(b, 0, 0)
    assert b.startswith("\n## Tasks\n- [ ] A\n  note\n  - [Epson (site)](https://epson.com/ff)\n- [x] B\n")
    with pytest.raises(ops.OpError):
        ops.body_add_task_file(b, 9, None, "https://x.org")
    with pytest.raises(ops.OpError):
        ops.body_remove_task_file(b, 2, 0)
    with pytest.raises(ops.OpError):
        ops.body_add_task_file(b, 0, None, "Documents/../etc/passwd")


def test_add_task_after_last_task_with_attachment():
    b = "\n## Tasks\n- [ ] A\n  - [x](https://x.org)\n\n## Notes\n"
    assert ops.body_add_task(b, "B") == "\n## Tasks\n- [ ] A\n  - [x](https://x.org)\n- [ ] B\n\n## Notes\n"


def test_attachments_move_and_delete_with_task():
    b = "\n## Tasks\n- [ ] A\n  - [a](https://a.org)\n- [ ] B\n  - [b](<Documents/b.pdf>)\n"
    assert ops.body_move_task(b, 1, 0) == "\n## Tasks\n- [ ] B\n  - [b](<Documents/b.pdf>)\n- [ ] A\n  - [a](https://a.org)\n"
    assert ops.body_remove_task(b, 0) == "\n## Tasks\n- [ ] B\n  - [b](<Documents/b.pdf>)\n"


def test_task_file_project_ops(tmp_path, monkeypatch):
    from pathlib import Path
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    d = tmp_path / "P"
    d.mkdir()
    (d / "README.md").write_text("---\ntitle: P\nstatus: active\n---\n\n## Tasks\n- [ ] Order scanner\n- [ ] Other\n")
    p = Project.load(d)
    f = ops.add_task_file(p, "scanner", f"{tmp_path}/Documents/Quotes/Epson.pdf")
    assert f == {"name": "Epson", "target": "Documents/Quotes/Epson.pdf", "kind": "file"}
    ops.add_task_file(p, "1", "https://epson.com", "Product page")
    assert [x["name"] for x in Project.load(d).tasks[0]["files"]] == ["Epson", "Product page"]
    with pytest.raises(ops.OpError):                   # outside ~/Documents
        ops.add_task_file(p, "1", f"{tmp_path}/Desktop/a.pdf")
    ops.edit_task_file(p, "1", "product", name="Epson site")
    assert ops.remove_task_file(p, "1", "1")["name"] == "Epson"
    assert Project.load(d).tasks[0]["files"] == [{"name": "Epson site", "target": "https://epson.com", "kind": "url"}]
    assert Project.load(d).tasks[1]["files"] == []


# ---- task notes (indented "  - text" lines under a task) ---------------------
NOTE = "\n## Tasks\n- [ ] A\n  - [Q](<Documents/q.pdf>)\n- [x] B\n  hand-written\n\n## Notes\n"


def test_notes_add_edit_remove_byte_exact():
    b = ops.body_add_task_note(NOTE, 0, "Call\nfirst")             # no notes yet: right under the task
    b = ops.body_add_task_note(b, 0, "  Then email  ")              # after the last note
    assert b == ("\n## Tasks\n- [ ] A\n  - Call first\n  - Then email\n  - [Q](<Documents/q.pdf>)\n"
                 "- [x] B\n  hand-written\n\n## Notes\n")
    t = Project(dir=None, body=b).tasks
    assert t[0]["notes"] == ["Call first", "Then email"] and [f["name"] for f in t[0]["files"]] == ["Q"]
    assert t[1]["notes"] == ["hand-written"]
    b = ops.body_add_task_note(b, 1, "Second")
    assert "- [x] B\n  hand-written\n  - Second\n\n## Notes\n" in b
    b = ops.body_edit_task_note(b, 1, 0, "Edited *note*")
    assert "- [x] B\n  - Edited *note*\n  - Second\n" in b
    b = ops.body_remove_task_note(b, 0, 0)
    assert b.startswith("\n## Tasks\n- [ ] A\n  - Then email\n  - [Q](<Documents/q.pdf>)\n- [x] B\n")
    assert ops.body_move_task(b, 1, 0).startswith("\n## Tasks\n- [x] B\n  - Edited *note*\n  - Second\n- [ ] A\n")
    assert ops.body_remove_task(b, 1) == "\n## Tasks\n- [ ] A\n  - Then email\n  - [Q](<Documents/q.pdf>)\n\n## Notes\n"
    for bad in [lambda: ops.body_add_task_note(b, 9, "x"), lambda: ops.body_add_task_note(b, 0, " \n "),
                lambda: ops.body_edit_task_note(b, 0, 5, "x"), lambda: ops.body_remove_task_note(b, 1, 2),
                lambda: ops.body_add_task_note(b, 0, "[link](https://x.org)")]:
        with pytest.raises(ops.OpError):
            bad()


def test_task_note_project_ops(tmp_path):
    d = tmp_path / "P"
    d.mkdir()
    (d / "README.md").write_text("---\ntitle: P\nstatus: active\n---\n\n## Tasks\n- [ ] Order scanner\n- [ ] Other\n")
    p = Project.load(d)
    assert ops.add_task_note(p, "scanner", "Ask about the warranty") == "Ask about the warranty"
    ops.add_task_note(p, "1", "Compare prices")
    assert ops.edit_task_note(p, "1", "prices", "Compare prices at B&H") == "Compare prices at B&H"
    assert ops.remove_task_note(p, "1", "1") == "Ask about the warranty"
    assert Project.load(d).tasks[0]["notes"] == ["Compare prices at B&H"]
    assert Project.load(d).tasks[1]["notes"] == []
    with pytest.raises(ops.OpError):
        ops.edit_task_note(p, "2", "1", "x")
