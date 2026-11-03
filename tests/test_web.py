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


def test_receipt_upload_serve_detach(client, ws):
    r = client.post("/p/Roof%20Repair/receipts", headers=HX,
                    files={"file": ("invoice.pdf", b"%PDF-1.4", "application/pdf")},
                    data={"amount": "$1,234.50", "vendor": "Lowes", "date": "2026-10-09", "desc": "Shingles"})
    assert r.status_code == 200, r.text
    rec = proj(ws).receipts[0]
    assert rec["path"] == "2026/2026-10-09 Shingles.pdf" and rec["amount"] == 1234.5
    assert client.get("/receipt", params={"path": rec["path"]}).content == b"%PDF-1.4"
    assert client.get("/receipt", params={"path": "../Projects/House/Roof Repair/README.md"}).status_code == 404
    client.post("/p/Roof%20Repair/receipts/1/delete", headers=HX)
    assert proj(ws).receipts == [] and (ws.receipts_root / rec["path"]).exists()


def test_status_close_reopen_rename(client, ws):
    client.post("/p/Roof%20Repair/status", data={"status": "on-hold"}, headers=HX)
    assert proj(ws).status == "on-hold"
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
