"""Project Files links. Literal expectations are mirrored in ios/ProjKit/Sources/Checks/main.swift."""
from pathlib import Path

import pytest

from projkit import ops
from projkit.lint import lint_workspace
from projkit.project import Project

BODY = "\n## Description\nx\n\n## Project Files\nSome notes about files.\n\n## Notes\n### 2026-11-02\n- n\n"
GDOC = "https://docs.google.com/document/d/1nkS9byPzwlKPAzqg9kLi-mdR3Z8tiebexaJj-OPYE3Q/edit?tab=t.0"


def test_add_file_and_url_entries():
    b = ops.body_add_file(BODY, "Scanner manual", "Documents/Manuals/Epson FF-680W.pdf")
    b = ops.body_add_file(b, "", GDOC)
    assert b == ("\n## Description\nx\n\n## Project Files\nSome notes about files.\n"
                 "- [Scanner manual](<Documents/Manuals/Epson FF-680W.pdf>)\n"
                 f"- [docs.google.com]({GDOC})\n\n## Notes\n### 2026-11-02\n- n\n")
    p = Project(dir=None, body=b)
    assert p.files == [
        {"name": "Scanner manual", "target": "Documents/Manuals/Epson FF-680W.pdf", "kind": "file"},
        {"name": "docs.google.com", "target": GDOC, "kind": "url"}]
    assert p.files_other_text == "Some notes about files."


def test_add_creates_section_and_defaults_names():
    b = ops.body_add_file("\n## Description\nx\n", None, "Documents/Taxes/2025 [final].pdf")
    assert b == "\n## Description\nx\n\n## Project Files\n- [2025 (final)](<Documents/Taxes/2025 [final].pdf>)\n"
    b = ops.body_add_file(b, "My (odd) [name]", "https://example.com/a b")
    assert b.endswith("- [My (odd) (name)](<https://example.com/a b>)\n")
    assert Project(dir=None, body=b).files[1]["target"] == "https://example.com/a b"


def test_edit_and_remove():
    b = ops.body_add_file(BODY, "A", "Documents/a.pdf")
    b = ops.body_add_file(b, "B", "https://b.example")
    b = ops.body_edit_file(b, 0, "Renamed", None)
    b = ops.body_edit_file(b, 1, None, "https://c.example/x")
    assert "- [Renamed](<Documents/a.pdf>)\n- [B](https://c.example/x)\n" in b
    b = ops.body_remove_file(b, 0)
    assert "- [Renamed]" not in b and "Some notes about files.\n- [B](https://c.example/x)\n" in b
    with pytest.raises(ops.OpError):
        ops.body_remove_file(b, 3)


@pytest.mark.parametrize("bad", ["/etc/passwd", "Downloads/x.pdf", "Documents/../x", "Documents/", "", "Documents/a<b"])
def test_rejects_bad_targets(bad):
    with pytest.raises(ops.OpError):
        ops.body_add_file(BODY, "x", bad)


def test_normalize_paths(tmp_path):
    home = tmp_path
    assert ops.normalize_file_path("~/Documents/a/b.pdf", home) == "Documents/a/b.pdf"
    assert ops.normalize_file_path(f"{home}/Documents/a/b.pdf", home) == "Documents/a/b.pdf"
    assert ops.normalize_file_path("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Documents/a.pdf",
                                   home) == "Documents/a.pdf"
    assert ops.normalize_file_path("  'Documents/x y.txt' ", home) == "Documents/x y.txt"
    assert ops.normalize_file_path(GDOC, home) == GDOC
    with pytest.raises(ops.OpError):
        ops.normalize_file_path(f"{home}/Desktop/a.pdf", home)
    (home / "Documents" / "a").mkdir(parents=True)
    assert ops.resolve_file("Documents/a", home) == (home / "Documents" / "a").resolve()


def test_project_level_and_lint(tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    (tmp_path / "Documents" / "Manuals").mkdir(parents=True)
    (tmp_path / "Documents" / "Manuals" / "m.pdf").write_bytes(b"%PDF")
    root = tmp_path / "Documents" / "Projects"
    from projkit.workspace import Workspace
    d = root / "House" / "Roof"
    (d / "Documents").mkdir(parents=True)
    (d / "Receipts").mkdir()
    p = Project(dir=d, body=BODY)
    p.meta.update(title="Roof", area="House", status="active")
    p.save()
    ops.add_file(p, str(tmp_path / "Documents/Manuals/m.pdf"), "Manual")
    ops.add_file(p, "Documents/Manuals/missing.pdf")
    ops.edit_file(p, "missing", name="Gone")
    ws = Workspace(root, tmp_path / "Receipts")
    l014 = [i for i in lint_workspace(ws) if i.code == "L014"]
    assert len(l014) == 1 and "Documents/Manuals/missing.pdf" in l014[0].message
    assert ops.remove_file(Project.load(d), "Gone")["target"] == "Documents/Manuals/missing.pdf"
    assert [f["name"] for f in Project.load(d).files] == ["Manual"]
