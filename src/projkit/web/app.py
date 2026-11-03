"""Local web UI. Every request re-reads the files, so CLI/Finder/iCloud edits show up immediately."""
from __future__ import annotations

import datetime as dt
import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from markdown_it import MarkdownIt

from .. import ops
from ..lint import lint_workspace
from ..project import STATUSES, Project
from ..workspace import Workspace

HERE = Path(__file__).parent
STATUS_ORDER = {"active": 0, "on-hold": 1, "idea": 2, "closed": 3}
_md = MarkdownIt("commonmark", {"html": False, "linkify": False}).enable(["strikethrough", "table"])


def render_md(text: str | None) -> str:
    return _md.render(text or "")


def safe_url(url) -> str:
    u = str(url or "")
    return u if u.lower().startswith(("http://", "https://", "mailto:")) else "#"


def _fmt_money(v) -> str:
    return f"${float(v or 0):,.2f}"


def create_app(ws: Workspace) -> FastAPI:
    app = FastAPI(title="Projects", docs_url=None, redoc_url=None, openapi_url=None)
    app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
    tpl = Jinja2Templates(directory=HERE / "templates")
    tpl.env.filters.update(md=render_md, safe_url=safe_url, money=_fmt_money,
                           q=lambda s: quote(str(s), safe=""),
                           tilde=lambda p: str(p).replace(str(Path.home()), "~", 1))
    tpl.env.globals.update(STATUSES=STATUSES, EDITABLE=ops.EDITABLE_SECTIONS)

    # ---- local-only guards -------------------------------------------------
    @app.middleware("http")
    async def guard(request: Request, call_next):
        host = (request.headers.get("host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost", "testserver"):
            return PlainTextResponse("forbidden host", status_code=403)   # DNS-rebinding guard
        if request.method not in ("GET", "HEAD") and request.headers.get("hx-request") != "true":
            return PlainTextResponse("missing HX-Request header", status_code=403)  # CSRF guard
        try:
            return await call_next(request)
        except ops.OpError as e:
            return PlainTextResponse(str(e), status_code=400)

    # ---- helpers -----------------------------------------------------------
    def page(request: Request, template: str, **ctx) -> HTMLResponse:
        ctx.setdefault("issue_count", sum(i.severity != "info" for i in lint_workspace(ws)))
        ctx.setdefault("nav", "")
        return tpl.TemplateResponse(request, template, ctx)

    def partial(request: Request, template: str, **ctx) -> HTMLResponse:
        return tpl.TemplateResponse(request, template, ctx)

    def get_project(key: str) -> Project:
        for p in ws.projects():
            if p.folder_name == key:
                return p
        raise HTTPException(404, f"No project '{key}'")

    def purl(p: Project) -> str:
        return f"/p/{quote(p.folder_name, safe='')}"

    def redirect(url: str) -> Response:
        return Response(status_code=204, headers={"HX-Redirect": url})

    def card(p: Project) -> dict:
        notes = p.notes
        done, total = p.goal_progress
        return dict(p=p, url=purl(p), area=p.area or ws.location_area(p) or "—",
                    status="legacy" if p.legacy else p.status, done=done, total=total,
                    pct=int(100 * done / total) if total else 0,
                    last_note=notes[-1].date if notes else None)

    def matches(p: Project, q: str) -> bool:
        q = q.lower()
        hay = [p.title, p.body, *p.tags, *(str(g.get("text", "")) for g in p.goals),
               *(str(l.get("title", "")) for l in p.links)]
        return any(q in h.lower() for h in hay)

    # ---- pages -------------------------------------------------------------
    @app.get("/", response_class=HTMLResponse)
    def dashboard(request: Request, status: str = "open", q: str = ""):
        projects = ws.projects(include_closed=status in ("closed", "all"))
        if status == "open":
            projects = [p for p in projects if p.status != "closed"]
        elif status != "all":
            projects = [p for p in projects if p.status == status]
        if q:
            projects = [p for p in projects if matches(p, q)]
        cards = sorted((card(p) for p in projects),
                       key=lambda c: (STATUS_ORDER.get(c["status"], 9), c["p"].title.lower()))
        areas = {a: [] for a in ws.areas()}
        for c in cards:
            areas.setdefault(c["area"], []).append(c)
        recent = sorted(((n, p) for p in ws.projects(include_closed=False) for n in p.notes if n.text),
                        key=lambda t: t[0].date, reverse=True)[:6]
        totals = dict(projects=len(cards), goals_open=sum(c["total"] - c["done"] for c in cards),
                      cost=sum(c["p"].total_cost for c in cards))
        return page(request, "dashboard.html", nav="projects", areas=areas, status=status, q=q,
                    recent=[(n, p, purl(p)) for n, p in recent], ideas=ops.ideas(ws), totals=totals)

    @app.get("/p/{key}", response_class=HTMLResponse)
    def project_page(request: Request, key: str):
        p = get_project(key)
        return page(request, "project.html", **_project_ctx(p))

    def _project_ctx(p: Project) -> dict:
        return dict(p=p, url=purl(p), card=card(p), areas=ws.areas(), closed=ws.is_in_closed(p),
                    notes=list(reversed(p.notes)), today=dt.date.today().isoformat())

    # ---- project partial updates -------------------------------------------
    def goals_partial(request: Request, p: Project):
        return partial(request, "_goals.html", **_project_ctx(Project.load(p.dir)))

    @app.post("/p/{key}/goals")
    def goal_add(request: Request, key: str, text: str = Form(...)):
        p = get_project(key)
        if text.strip():
            ops.add_goal(p, text)
        return goals_partial(request, p)

    @app.post("/p/{key}/goals/{n}/toggle")
    def goal_toggle(request: Request, key: str, n: int):
        p = get_project(key)
        ops.set_goal(p, str(n), not p.goals[n - 1].get("done") if 0 < n <= len(p.goals) else True)
        return goals_partial(request, p)

    @app.post("/p/{key}/goals/{n}/delete")
    def goal_delete(request: Request, key: str, n: int):
        p = get_project(key)
        ops.remove_goal(p, str(n))
        return goals_partial(request, p)

    @app.post("/p/{key}/notes")
    def note_add(request: Request, key: str, text: str = Form(...)):
        p = get_project(key)
        if text.strip():
            ops.add_note(p, text)
        return partial(request, "_notes.html", **_project_ctx(Project.load(p.dir)))

    @app.post("/p/{key}/links")
    def link_add(request: Request, key: str, url: str = Form(...), title: str = Form("")):
        p = get_project(key)
        ops.add_link(p, url.strip(), title.strip() or None)
        return partial(request, "_links.html", **_project_ctx(Project.load(p.dir)))

    @app.post("/p/{key}/links/{n}/delete")
    def link_delete(request: Request, key: str, n: int):
        p = get_project(key)
        ops.remove_link(p, n - 1)
        return partial(request, "_links.html", **_project_ctx(Project.load(p.dir)))

    @app.post("/p/{key}/receipts")
    async def receipt_add(request: Request, key: str, file: UploadFile = File(...),
                          amount: str = Form(""), vendor: str = Form(""), date: str = Form(""),
                          desc: str = Form("")):
        p = get_project(key)
        name = Path(file.filename or "receipt.pdf").name
        try:
            amt = float(amount.replace("$", "").replace(",", "")) if amount.strip() else None
            d = dt.date.fromisoformat(date) if date else None
        except ValueError as e:
            raise ops.OpError(f"invalid amount or date: {e}")
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td) / name
            with tmp.open("wb") as f:
                shutil.copyfileobj(file.file, f)
            ops.add_receipt(ws, p, tmp, amt, vendor.strip() or None, d,
                            desc.strip() or Path(name).stem, move=True)
        return partial(request, "_receipts.html", **_project_ctx(Project.load(p.dir)))

    @app.post("/p/{key}/receipts/{n}/delete")
    def receipt_delete(request: Request, key: str, n: int):
        p = get_project(key)
        ops.remove_receipt(p, n - 1)
        return partial(request, "_receipts.html", **_project_ctx(Project.load(p.dir)))

    @app.get("/receipt")
    def receipt_file(path: str):
        root = ws.receipts_root.resolve()
        f = (root / path).resolve()
        if not f.is_relative_to(root) or not f.is_file():
            raise HTTPException(404)
        return FileResponse(f, content_disposition_type="inline", filename=f.name)

    @app.get("/p/{key}/section/{name}", response_class=HTMLResponse)
    def section_view(request: Request, key: str, name: str, edit: bool = False):
        p = get_project(key)
        return partial(request, "_section.html", **_project_ctx(p), name=name,
                       text=p.section(name) or "", edit=edit)

    @app.post("/p/{key}/section/{name}", response_class=HTMLResponse)
    def section_save(request: Request, key: str, name: str, text: str = Form("")):
        p = get_project(key)
        ops.set_section(p, name, text)
        p = Project.load(p.dir)
        return partial(request, "_section.html", **_project_ctx(p), name=name,
                       text=p.section(name) or "", edit=False)

    @app.post("/p/{key}/status")
    def status_set(request: Request, key: str, status: str = Form(...)):
        p = get_project(key)
        ops.set_status(p, status)
        return redirect(purl(p))

    @app.post("/p/{key}/close")
    def close(key: str):
        return redirect(purl(ops.close(ws, get_project(key))))

    @app.post("/p/{key}/reopen")
    def reopen(key: str, area: str = Form("")):
        return redirect(purl(ops.reopen(ws, get_project(key), area or None)))

    @app.post("/p/{key}/rename")
    def rename(key: str, title: str = Form(...)):
        return redirect(purl(ops.rename(ws, get_project(key), title)))

    @app.post("/p/{key}/reveal")
    def reveal(key: str):
        subprocess.run(["open", str(get_project(key).dir)], check=False)
        return Response(status_code=204)

    # ---- new project / ideas -----------------------------------------------
    @app.get("/new", response_class=HTMLResponse)
    def new_form(request: Request, area: str = ""):
        return page(request, "new.html", nav="new", areas=ws.areas(), area=area)

    @app.post("/new")
    def new_create(title: str = Form(...), area: str = Form(...), status: str = Form("active")):
        return redirect(purl(ops.new_project(ws, title, area, status)))

    @app.get("/ideas", response_class=HTMLResponse)
    def ideas_page(request: Request):
        return page(request, "ideas.html", nav="ideas", ideas=ops.ideas(ws), areas=ws.areas())

    def ideas_partial(request: Request):
        return partial(request, "_ideas.html", ideas=ops.ideas(ws), areas=ws.areas())

    @app.post("/ideas")
    def idea_add(request: Request, text: str = Form(...)):
        if text.strip():
            ops.add_idea(ws, text)
        return ideas_partial(request)

    @app.post("/ideas/{n}/delete")
    def idea_delete(request: Request, n: int):
        ops.remove_idea(ws, str(n))
        return ideas_partial(request)

    @app.post("/ideas/{n}/promote")
    def idea_promote(n: int, area: str = Form(...), title: str = Form("")):
        return redirect(purl(ops.promote_idea(ws, str(n), area, title.strip() or None)))

    # ---- lint --------------------------------------------------------------
    @app.get("/lint", response_class=HTMLResponse)
    def lint_page(request: Request):
        issues = lint_workspace(ws)
        rows = [dict(i=i, rel=str(i.path.relative_to(ws.root)) if i.path.is_relative_to(ws.root) else str(i.path))
                for i in issues]
        return page(request, "lint.html", nav="lint", rows=rows)

    @app.post("/lint/fix")
    def lint_fix(code: str = Form(...), path: str = Form(...)):
        for i in lint_workspace(ws):
            if i.code == code and str(i.path) == path and i.fix:
                try:
                    i.fix()
                except OSError as e:
                    raise ops.OpError(str(e))
                return redirect("/lint")
        raise ops.OpError("issue no longer present or not fixable")

    # ---- live refresh + JSON -----------------------------------------------
    @app.get("/api/fingerprint", response_class=PlainTextResponse)
    def fingerprint():
        """Changes when any README, the backlog, or the area/project folder set changes.
        Only stats the top two levels — never walks Documents/."""
        h = hashlib.sha1()
        paths = [ws.root, ws.closed_dir, *ws.root.glob("*.md"), *ws.area_dirs()]
        for p in ws.projects():
            paths += [p.dir, p.readme]
        for f in paths:
            try:
                h.update(f"{f}:{f.stat().st_mtime_ns}".encode())
            except OSError:
                h.update(f"{f}:-".encode())
        return h.hexdigest()

    @app.get("/api/projects")
    def api_projects():
        out = []
        for p in ws.projects():
            done, total = p.goal_progress
            out.append(dict(folder=p.folder_name, title=p.title, area=p.area or ws.location_area(p),
                            status="legacy" if p.legacy else p.status, goals_done=done, goals_total=total,
                            cost=p.total_cost, path=str(p.dir)))
        return JSONResponse(out)

    return app
