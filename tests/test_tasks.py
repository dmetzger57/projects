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
    assert p.tasks == [{"text": "one", "done": False}, {"text": "two", "done": True}]
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
    assert ops.set_task(p, "roofer", True) == {"text": "Hire roofer", "done": True}
    ops.edit_task(p, "1", "Buy cedar shingles")
    q = Project.load(d)
    assert q.tasks == [{"text": "Buy cedar shingles", "done": False}, {"text": "Hire roofer", "done": True}]
    assert q.task_progress == (1, 2)
    ops.remove_task(q, "cedar")
    assert Project.load(d).tasks == [{"text": "Hire roofer", "done": True}]
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
