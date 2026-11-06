import datetime as dt
from pathlib import Path

import pytest

from projkit import ops
from projkit.lint import lint_workspace
from projkit.project import Project, parse_photo_line
from projkit.workspace import Workspace

JPEG = b"\xff\xd8\xff\xe0fake-jpeg"
NOW = dt.datetime(2026, 11, 6, 10, 12, 30)


@pytest.fixture
def ws(tmp_path: Path) -> Workspace:
    root = tmp_path / "Projects"
    for d in ("1 - Template", "2 - Closed", "House"):
        (root / d).mkdir(parents=True)
    w = Workspace(root, tmp_path / "Receipts")
    p = ops.new_project(w, "Roof", "House")
    ops.add_task(p, "Patch the leak")
    ops.add_task_note(p, "1", "Above the garage")
    return w


def roof(ws) -> Project:
    return ws.find("Roof")[0]


def test_parse_photo_lines():
    assert parse_photo_line("- ![Leak](<Photos/a b.jpg>)") == {"note": "Leak", "path": "Photos/a b.jpg"}
    assert parse_photo_line("- ![](Photos/a.jpg)") == {"note": "", "path": "Photos/a.jpg"}
    for line in ("- ![x](<Documents/a.jpg>)", "- ![x](<Photos/sub/a.jpg>)", "- ![x](<Photos/../a.jpg>)",
                 "- [x](<Photos/a.jpg>)", "- ![x](<Photos/>)"):
        assert parse_photo_line(line) is None, line


def test_body_photo_format_is_stable():
    body = "## Description\nx\n\n## Notes\n### 2026-11-06\n- hi\n"
    b = ops.body_add_photo(body, "Before [1]\nfront", "Photos/a.jpg")
    assert b == ("## Description\nx\n\n## Photos\n- ![Before (1) front](<Photos/a.jpg>)\n\n"
                 "## Notes\n### 2026-11-06\n- hi\n")
    b = ops.body_add_photo(b, "", "Photos/b.jpg")
    assert "- ![Before (1) front](<Photos/a.jpg>)\n- ![](<Photos/b.jpg>)\n\n## Notes" in b
    assert ops.body_edit_photo(b, 1, "After") == b.replace("![](<Photos/b.jpg>)", "![After](<Photos/b.jpg>)")
    assert ops.body_remove_photo(b, 0) == b.replace("- ![Before (1) front](<Photos/a.jpg>)\n", "")
    t = ops.body_add_task_photo("## Tasks\n- [ ] One\n  - note\n  - [F](<Documents/f.pdf>)\n- [ ] Two\n", 0, "Leak",
                                "Photos/c.jpg")
    assert t == "## Tasks\n- [ ] One\n  - note\n  - [F](<Documents/f.pdf>)\n  - ![Leak](<Photos/c.jpg>)\n- [ ] Two\n"
    assert ops.body_edit_task_photo(t, 0, 0, "Leak, fixed").count("![Leak, fixed](<Photos/c.jpg>)") == 1
    assert ops.body_remove_task_photo(t, 0, 0) == "## Tasks\n- [ ] One\n  - note\n  - [F](<Documents/f.pdf>)\n- [ ] Two\n"


def test_project_and_task_photos(ws):
    p = roof(ws)
    ph = ops.add_photo(p, JPEG, ".JPG", "Front of house", now=NOW)
    assert ph["note"] == "Front of house" and ph["path"].startswith("Photos/2026-11-06 101230-") and ph["path"].endswith(".jpg")
    assert (p.dir / ph["path"]).read_bytes() == JPEG
    tph = ops.add_photo(roof(ws), JPEG, "png", "Leak", task="1")
    t = roof(ws).tasks[0]
    assert t["photos"] == [tph] and t["notes"] == ["Above the garage"]      # photos aren't notes
    assert ops.edit_photo_note(roof(ws), "1", "Front")["note"] == "Front"
    assert ops.edit_photo_note(roof(ws), "leak", "Leak (fixed)", task="1")["note"] == "Leak (fixed)"
    with pytest.raises(ops.OpError):
        ops.add_photo(roof(ws), JPEG, ".pdf")
    with pytest.raises(ops.OpError):
        ops.add_task_note(roof(ws), "1", f"![x](<{tph['path']}>)")
    ops.remove_photo(roof(ws), "1")
    assert roof(ws).photos == [] and not (p.dir / ph["path"]).exists()
    ops.remove_task(roof(ws), "1")                                    # task photos go with the task
    assert not (p.dir / tph["path"]).exists()


def test_photos_move_with_archived_tasks_and_renames(ws):
    tph = ops.add_photo(roof(ws), JPEG, ".jpg", "Leak", task="1")
    ops.archive_task(ws, roof(ws), "1", dt.date(2026, 11, 6))
    a = ws.archive()
    assert a.tasks[0]["photos"] == [tph] and (a.dir / tph["path"]).exists()
    assert not (roof(ws).dir / tph["path"]).exists()
    ops.restore_task(ws, "1")
    assert roof(ws).tasks[-1]["photos"] == [tph] and (roof(ws).dir / tph["path"]).exists()
    assert not (a.dir / tph["path"]).exists()
    p = ops.rename(ws, roof(ws), "Roof Repair")                       # Photos/ moves with the folder
    assert (p.dir / tph["path"]).exists()


def test_lint_reports_missing_photo(ws):
    ph = ops.add_photo(roof(ws), JPEG, ".jpg", "Front")
    (roof(ws).dir / ph["path"]).unlink()
    assert any(i.code == "L015" for i in lint_workspace(ws))
