from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from projkit import ops
from projkit.project import Project
from projkit.web.app import create_app
from projkit.workspace import Workspace

HX = {"HX-Request": "true"}


@pytest.fixture
def ws(tmp_path: Path, monkeypatch) -> Workspace:
    root, rec = tmp_path / "Projects", tmp_path / "Receipts"
    for d in ("1 - Template/Documents", "1 - Template/Receipts", "2 - Closed", "House", "Personal"):
        (root / d).mkdir(parents=True)
    rec.mkdir()
    monkeypatch.setattr(ops, "tag_file", lambda p, tag="receipt": None)
    w = Workspace(root, rec)
    p = ops.new_project(w, "Roof Repair", "House")
    ops.add_goal(p, "Get quotes")
    ops.add_note(p, "Leak over **garage**")
    ops.add_idea(w, "Backyard Sequoia tree")
    return w


@pytest.fixture
def client(ws) -> TestClient:
    return TestClient(create_app(ws))


def proj(ws) -> Project:
    return ws.find("Roof Repair")[0]


def test_pages_render(client):
    r = client.get("/")
    assert r.status_code == 200 and "Roof Repair" in r.text and "Personal" in r.text
    r = client.get("/p/Roof%20Repair")
    assert r.status_code == 200 and "Get quotes" in r.text and "<strong>garage</strong>" in r.text
    for url in ("/ideas", "/lint", "/new", "/api/projects", "/api/fingerprint"):
        assert client.get(url).status_code == 200, url
    assert client.get("/p/Nope").status_code == 404


def test_search_and_filters(client):
    card = 'class="card" href="/p/Roof%20Repair"'
    assert card in client.get("/?q=quotes").text
    assert card not in client.get("/?q=zzz").text
    assert card not in client.get("/?status=closed").text


def test_mutations_require_hx_header_and_local_host(client):
    assert client.post("/ideas", data={"text": "x"}).status_code == 403
    assert client.get("/", headers={"Host": "evil.example"}).status_code == 403


def test_goal_toggle_add_delete(client, ws):
    r = client.post("/p/Roof%20Repair/goals/1/toggle", headers=HX)
    assert r.status_code == 200 and "checked" in r.text
    assert proj(ws).goal_progress == (1, 1)
    client.post("/p/Roof%20Repair/goals", data={"text": "Hire roofer"}, headers=HX)
    client.post("/p/Roof%20Repair/goals/1/delete", headers=HX)
    assert [g["text"] for g in proj(ws).goals] == ["Hire roofer"]


def test_notes_links_sections(client, ws):
    client.post("/p/Roof%20Repair/notes", data={"text": "Called roofer"}, headers=HX)
    assert "Called roofer" in proj(ws).notes[-1].text
    client.post("/p/Roof%20Repair/links", data={"url": "https://example.com", "title": "Ex"}, headers=HX)
    assert proj(ws).links[0]["url"] == "https://example.com"
    r = client.post("/p/Roof%20Repair/links", data={"url": "javascript:alert(1)"}, headers=HX)
    assert r.status_code == 400
    r = client.post("/p/Roof%20Repair/section/Description", data={"text": "Fix the **roof**"}, headers=HX)
    assert "<strong>roof</strong>" in r.text
    p = proj(ws)
    assert p.section("Description") == "Fix the **roof**"
    assert p.notes[-1].text.endswith("Called roofer")       # notes untouched by section edit
    client.post("/p/Roof%20Repair/links/1/delete", headers=HX)
    assert proj(ws).links == []


def test_section_rejects_headings_and_unknown(client):
    assert client.post("/p/Roof%20Repair/section/Description", data={"text": "## Evil"}, headers=HX).status_code == 400
    assert client.post("/p/Roof%20Repair/section/Notes", data={"text": "x"}, headers=HX).status_code == 400


def test_receipt_reference_serve_detach(client, ws):
    src = ws.receipts_root / "2026" / "invoice.pdf"
    src.parent.mkdir(parents=True)
    src.write_bytes(b"%PDF-1.4")
    r = client.post("/p/Roof%20Repair/receipts", headers=HX,
                    data={"target": str(src), "amount": "$1,234.50", "vendor": "Lowes", "date": "2026-10-09"})
    assert r.status_code == 200, r.text
    rec = proj(ws).receipts[0]
    assert rec["path"] == "2026/invoice.pdf" and rec["amount"] == 1234.5
    assert [f.name for f in ws.receipts_root.rglob("*") if f.is_file()] == ["invoice.pdf"]   # no copy
    assert client.get("/p/Roof%20Repair/receipts/1").content == b"%PDF-1.4"
    assert client.get("/p/Roof%20Repair/receipts/2").status_code == 404
    client.post("/p/Roof%20Repair/receipts/1/delete", headers=HX)
    assert proj(ws).receipts == [] and src.exists()


def test_status_close_reopen_rename(client, ws):
    client.post("/p/Roof%20Repair/status", data={"status": "on-hold"}, headers=HX)
    assert proj(ws).status == "on-hold"
    for st in ("blocked", "backlog"):
        client.post("/p/Roof%20Repair/status", data={"status": st}, headers=HX)
        assert proj(ws).status == st
        home = client.get(f"/?status={st}").text
        assert "Roof Repair" in home and f'pill s-{st}' in home
    assert "pill s-backlog" not in client.get("/?status=blocked").text      # filtered out
    assert '<option value="blocked"' in client.get("/p/Roof%20Repair").text
    r = client.post("/p/Roof%20Repair/close", headers=HX)
    assert r.headers["HX-Redirect"] == "/p/Roof%20Repair"
    assert ws.is_in_closed(proj(ws))
    client.post("/p/Roof%20Repair/reopen", data={"area": "Personal"}, headers=HX)
    assert proj(ws).dir.parent.name == "Personal"
    r = client.post("/p/Roof%20Repair/rename", data={"title": "Roof"}, headers=HX)
    assert r.headers["HX-Redirect"] == "/p/Roof"


def test_new_and_ideas(client, ws):
    r = client.post("/new", data={"title": "Garden Beds", "area": "House"}, headers=HX)
    assert r.headers["HX-Redirect"] == "/p/Garden%20Beds"
    assert client.post("/new", data={"title": "Garden Beds", "area": "Personal"}, headers=HX).status_code == 400
    client.post("/ideas", data={"text": "Solar"}, headers=HX)
    r = client.post("/ideas/1/promote", data={"area": "House"}, headers=HX)
    assert r.headers["HX-Redirect"] == "/p/Backyard%20Sequoia%20tree"
    assert ops.ideas(ws) == ["Solar"]


def test_lint_fix(client, ws):
    (proj(ws).dir / "Receipts").rmdir()
    assert "missing Receipts" in client.get("/lint").text
    path = str(proj(ws).dir / "Receipts")
    r = client.post("/lint/fix", data={"code": "L002", "path": path}, headers=HX)
    assert r.status_code == 204 and Path(path).is_dir()


def test_fingerprint_changes_on_edit(client, ws):
    a = client.get("/api/fingerprint").text
    import time; time.sleep(0.01)
    ops.add_note(proj(ws), "x")
    assert client.get("/api/fingerprint").text != a


def test_tasks_add_toggle_edit_delete(client, ws):
    url = "/p/Roof%20Repair"
    r = client.post(f"{url}/tasks", data={"text": "Buy shingles"}, headers=HX)
    assert r.status_code == 200 and "Buy shingles" in r.text and 'id="tasks"' in r.text
    client.post(f"{url}/tasks", data={"text": "Hire roofer"}, headers=HX)
    client.post(f"{url}/tasks/2/toggle", headers=HX)
    assert proj(ws).tasks == [{"text": "Buy shingles", "done": False, "files": [], "notes": []}, {"text": "Hire roofer", "done": True, "files": [], "notes": []}]
    r = client.get(f"{url}/tasks?edit=1")
    assert 'value="Buy shingles"' in r.text and "/tasks/1/edit" in r.text
    client.post(f"{url}/tasks/1/edit", data={"text": "Buy cedar shingles"}, headers=HX)
    client.post(f"{url}/tasks/2/delete", headers=HX)
    assert proj(ws).tasks == [{"text": "Buy cedar shingles", "done": False, "files": [], "notes": []}]
    assert client.post(f"{url}/tasks/1/edit", data={"text": "  "}, headers=HX).status_code == 400
    page = client.get(url).text
    assert "Buy cedar shingles" in page and page.index('id="tasks"') < page.index("Project Files")
    home = client.get("/").text
    assert "0 of 1 tasks done" in home and "<span>0/1</span>" in home
    assert "<b>1</b><span>open tasks</span>" in home
    assert "0 of 1 tasks done" in client.get("/p/Roof%20Repair/tasks").text


def test_task_move_route(client, ws):
    url = "/p/Roof%20Repair"
    for t in ("one", "two", "three"):
        client.post(f"{url}/tasks", data={"text": t}, headers=HX)
    r = client.post(f"{url}/tasks/3/move", data={"to": "1"}, headers=HX)
    assert r.status_code == 200 and 'data-task-handle="1"' in r.text
    assert [t["text"] for t in proj(ws).tasks] == ["three", "one", "two"]
    client.post(f"{url}/tasks/1/move", data={"to": "3"}, headers=HX)
    assert [t["text"] for t in proj(ws).tasks] == ["one", "two", "three"]


def test_project_files_panel(client, ws, tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    docs = tmp_path / "Documents"
    (docs / "Manuals").mkdir(parents=True)
    (docs / "Manuals" / "Epson FF-680W.pdf").write_bytes(b"%PDF")
    (docs / "Plan.pages").mkdir()                       # package: shown as a file
    url = "/p/Roof%20Repair"
    r = client.post(f"{url}/files", data={"target": "Documents/Manuals/Epson FF-680W.pdf", "name": ""}, headers=HX)
    assert r.status_code == 200 and "Epson FF-680W" in r.text and "📄" in r.text
    gdoc = "https://docs.google.com/document/d/abc/edit?tab=t.0"
    client.post(f"{url}/files", data={"target": gdoc, "name": "Plan"}, headers=HX)
    client.post(f"{url}/files", data={"target": "Documents/missing.pdf", "name": "Gone"}, headers=HX)
    page = client.get(url).text
    assert f'href="{gdoc}"' in page and ">Plan</a>" in page and "file not found" in page
    assert page.index('id="tasks"') < page.index('id="files"')
    assert client.get(f"{url}/files?edit=2").text.count(f'value="{gdoc}"') == 1
    client.post(f"{url}/files/2/edit", data={"target": gdoc, "name": "Planning doc"}, headers=HX)
    client.post(f"{url}/files/3/delete", headers=HX)
    assert [f["name"] for f in proj(ws).files] == ["Epson FF-680W", "Planning doc"]
    assert client.post(f"{url}/files", data={"target": "/etc/passwd"}, headers=HX).status_code == 400
    # browser
    b = client.get("/browse", params={"path": "Documents"}).text
    assert 'data-browse-to="Documents/Manuals"' in b and 'data-pick-path="Documents/Plan.pages"' in b
    assert 'data-browse-to="Documents/Plan.pages"' not in b
    assert 'data-pick-path="Documents/Manuals/Epson FF-680W.pdf"' in client.get("/browse", params={"path": "Documents/Manuals"}).text
    assert client.get("/browse", params={"path": "Documents/../.."}).status_code == 400
    # raw text edit of the section still works and returns the panel
    r = client.post(f"{url}/section/Project%20Files", data={"text": "Notes about files\n\n- [X](https://x.example)"}, headers=HX)
    assert 'id="files"' in r.text and "Notes about files" in r.text and proj(ws).files[0]["name"] == "X"


def test_task_attachments_web(client, ws, tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    (tmp_path / "Documents").mkdir(exist_ok=True)
    (tmp_path / "Documents" / "quote.pdf").write_bytes(b"%PDF")
    client.post("/p/Roof%20Repair/tasks", data={"text": "Get quote"}, headers=HX)
    assert 'placeholder="Documents/Folder/file.pdf' in client.get("/p/Roof%20Repair/tasks?attach=1").text
    r = client.post("/p/Roof%20Repair/tasks/1/files", data={"target": "Documents/quote.pdf", "name": ""}, headers=HX)
    assert r.status_code == 200 and "quote" in r.text
    client.post("/p/Roof%20Repair/tasks/1/files", data={"target": "https://roofer.example", "name": "Roofer"}, headers=HX)
    t = proj(ws).tasks[0]
    assert [f["target"] for f in t["files"]] == ["Documents/quote.pdf", "https://roofer.example"]
    assert "Roofer" in client.get("/p/Roof%20Repair").text
    client.post("/p/Roof%20Repair/tasks/1/files/1/delete", headers=HX)
    assert [f["name"] for f in proj(ws).tasks[0]["files"]] == ["Roofer"]
    assert (tmp_path / "Documents" / "quote.pdf").exists()


def test_task_notes_web(client, ws):
    url = "/p/Roof%20Repair"
    client.post(f"{url}/tasks", data={"text": "Get quote"}, headers=HX)
    assert 'placeholder="Add a note"' in client.get(f"{url}/tasks?note=1").text
    r = client.post(f"{url}/tasks/1/notes", data={"text": "Ask about <gutters>"}, headers=HX)
    assert r.status_code == 200 and "Ask about &lt;gutters&gt;" in r.text and 'class="plain task-notes"' in r.text
    client.post(f"{url}/tasks/1/notes", data={"text": "Two quotes minimum"}, headers=HX)
    assert proj(ws).tasks[0]["notes"] == ["Ask about <gutters>", "Two quotes minimum"]
    r = client.get(f"{url}/tasks?note_edit=1.2")
    assert 'value="Two quotes minimum"' in r.text and "/tasks/1/notes/2/edit" in r.text
    assert client.get(f"{url}/tasks?note_edit=x").status_code == 400
    client.post(f"{url}/tasks/1/notes/2/edit", data={"text": "Three quotes"}, headers=HX)
    client.post(f"{url}/tasks/1/notes/1/delete", headers=HX)
    assert proj(ws).tasks[0]["notes"] == ["Three quotes"]
    assert client.post(f"{url}/tasks/1/notes/1/edit", data={"text": " "}, headers=HX).status_code == 400
    assert client.post(f"{url}/tasks/1/notes/5/delete", headers=HX).status_code == 400
    assert "Three quotes" in client.get(url).text
