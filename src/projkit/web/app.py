"""Local web UI. Every request re-reads the files, so CLI/Finder/iCloud edits show up immediately."""
from __future__ import annotations

import datetime as dt
import hashlib
import subprocess
from pathlib import Path
from urllib.parse import quote

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from markdown_it import MarkdownIt

from .. import ops, reminders
from ..about import version_string
from ..lint import lint_workspace
from ..project import STATUSES, Project, ProjectError, status_label
from ..workspace import ARCHIVE_DIR, TODAY_DIR
from ..workspace import Workspace

HERE = Path(__file__).parent
# macOS document packages: folders on disk, but files to the user
PACKAGE_SUFFIXES = {".pages", ".numbers", ".key", ".app", ".bundle", ".photoslibrary", ".rtfd", ".band",
                    ".logicx", ".fcpbundle", ".imovielibrary", ".playground", ".xcodeproj"}
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
    tpl.env.globals.update(STATUSES=STATUSES, status_label=status_label, reminder_label=reminders.reminder_label, EDITABLE=ops.EDITABLE_SECTIONS, VERSION=version_string())

    def asset(name: str) -> str:
        """/static/<name>?v=<mtime>: a changed file gets a new URL, so browsers never keep a stale copy."""
        try:
            return f"/static/{name}?v={int((HERE / 'static' / name).stat().st_mtime)}"
        except OSError:
            return f"/static/{name}"
    tpl.env.globals.update(asset=asset)

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
        except ProjectError as e:          # OpError and unreadable-README refusals
            return PlainTextResponse(str(e), status_code=400)

    # ---- helpers -----------------------------------------------------------
    def page(request: Request, template: str, **ctx) -> HTMLResponse:
        ctx.setdefault("issue_count", sum(i.severity != "info" for i in lint_workspace(ws)))
        ctx.setdefault("nav", "")
        return tpl.TemplateResponse(request, template, ctx)

    def partial(request: Request, template: str, **ctx) -> HTMLResponse:
        return tpl.TemplateResponse(request, template, ctx)

    def get_project(key: str) -> Project:
        if key == TODAY_DIR:
            return ops.ensure_today(ws)
        if key == ARCHIVE_DIR:
            return ops.ensure_archive(ws)
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
        tdone, ttotal = p.task_progress
        return dict(p=p, url=purl(p), area=ops.project_area(ws, p),
                    status="legacy" if p.legacy else p.status, done=done, total=total,
                    pct=int(100 * done / total) if total else 0,
                    tdone=tdone, ttotal=ttotal, tpct=int(100 * tdone / ttotal) if ttotal else 0,
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
        ov = ops.overview(ws)
        by_area: dict[str, list[Project]] = {a: [] for a in ws.areas()}
        for p in projects:
            by_area.setdefault(ops.project_area(ws, p), []).append(p)
        areas = {a: [card(p) for p in ops.sort_projects(ov, a, by_area[a])]
                 for a in ops.sort_areas(ov, list(by_area))}
        cards = [c for cs in areas.values() for c in cs]
        recent = sorted(((n, p) for p in ws.projects(include_closed=False) for n in p.notes if n.text),
                        key=lambda t: t[0].date, reverse=True)[:6]
        totals = dict(projects=len(cards), goals_open=sum(c["total"] - c["done"] for c in cards),
                      tasks_open=sum(c["ttotal"] - c["tdone"] for c in cards),
                      cost=sum(c["p"].total_cost for c in cards))
        return page(request, "dashboard.html", nav="projects", areas=areas, status=status, q=q,
                    manual={a for a in areas if ov.has_order(a)}, collapsed={a for a in areas if ov.is_collapsed(a)},
                    areas_manual=bool(ov.areas),
                    recent=[(n, p, purl(p)) for n, p in recent], ideas=ops.ideas(ws), totals=totals)

    # ---- overview layout: collapsed tiles, manual order ----------------------
    @app.post("/area/collapse")
    def area_collapse(area: str = Form(""), collapsed: int = Form(...), all: int = Form(0)):
        ops.set_collapsed(ws, ops.overview_areas(ws) if all else [area], bool(collapsed))
        return _refresh()

    @app.post("/area/move")
    def area_move(area: str = Form(...), before: str = Form(""), after: str = Form("")):
        if not (before or after):
            raise HTTPException(400, "before or after is required")
        ops.move_area(ws, area, before=before or None, after=after or None)
        return _refresh()

    @app.post("/areas/order/reset")
    def areas_order_reset():
        ops.reset_area_order(ws)
        return _refresh()

    @app.post("/p/{key}/order")
    def project_order(key: str, before: str = Form(""), after: str = Form("")):
        if not (before or after):
            raise HTTPException(400, "before or after is required")
        ops.move_project(ws, get_project(key), before=before or None, after=after or None)
        return _refresh()

    @app.post("/area/order/reset")
    def area_order_reset(area: str = Form(...)):
        ops.reset_order(ws, area)
        return _refresh()

    @app.get("/p/{key}", response_class=HTMLResponse)
    def project_page(request: Request, key: str):
        p = get_project(key)
        if ws.is_archive(p):
            return archive_page(request)
        if ws.is_today(p):
            return page(request, "today.html", nav="today", today_date=dt.date.today().strftime("%A, %B %-d"),
                        **_project_ctx(p))
        return page(request, "project.html", **_project_ctx(p))

    @app.get("/today", response_class=HTMLResponse)
    def today_page(request: Request):
        return project_page(request, TODAY_DIR)

    # ---- All Open Tasks (a peer of Today): every open task, by project; copy a selection to Today ----
    def open_tasks_ctx(copied: int | None = None, skipped: int = 0, form: str | None = None,
                       pick: str | None = None, done_msg: str | None = None) -> dict:
        in_today = ops.today_ids(ws)
        groups = [dict(area=g["area"], p=g["project"], url=purl(g["project"]),
                       tasks=[dict(n=i + 1, t=t, in_today=t["id"] in in_today) for i, t in g["tasks"]])
                  for g in ops.open_tasks(ws)]
        tomorrow = (dt.datetime.now() + dt.timedelta(days=1)).replace(hour=9, minute=0)
        return dict(groups=groups, total=sum(len(g["tasks"]) for g in groups), copied=copied, skipped=skipped,
                    form_kind=form, form_pick=pick, done_msg=done_msg,
                    remind_default=tomorrow.strftime("%Y-%m-%dT%H:%M"), reminder_list=reminders.REMINDER_LIST,
                    photo_src=lambda url, path: f"{url}/photo/{quote(path.split('/', 1)[1], safe='')}")

    OPEN_FORMS = ("edit", "note", "photo", "link", "remind")

    def _pick(v: str) -> tuple[str, int]:
        """ "<project folder>:<task number>" -> (folder, 0-based index)."""
        folder, _, n = str(v).rpartition(":")
        if not folder or not n.isdigit() or int(n) < 1:
            raise HTTPException(400, f"bad pick {v!r}")
        return folder, int(n) - 1

    @app.get("/tasks/list", response_class=HTMLResponse)
    def open_tasks_list(request: Request, form: str | None = None, pick: str | None = None):
        """The Open Tasks list alone; with `form` (edit|note|photo|link|remind) and `pick` ("<folder>:<n>"),
        that task shows the form inline."""
        if form is not None and (form not in OPEN_FORMS or not pick):
            raise HTTPException(400, f"bad form {form!r}")
        return partial(request, "_open_tasks.html", **open_tasks_ctx(form=form, pick=pick))

    def _picked(pick: str) -> tuple[Project, str, dict]:
        """(project, 1-based task ref, task) of a pick."""
        folder, i = _pick(pick)
        p = get_project(folder)
        if not 0 <= i < len(p.tasks):
            raise ops.OpError(f"no task #{i + 1} in {p.title}")
        return p, str(i + 1), p.tasks[i]

    def open_done(request: Request, msg: str):
        return partial(request, "_open_tasks.html", **open_tasks_ctx(done_msg=msg))

    @app.post("/tasks/edit", response_class=HTMLResponse)
    def open_tasks_edit(request: Request, pick: str = Form(...), text: str = Form(...)):
        p, ref, _ = _picked(pick)
        ops.edit_task(p, ref, text)
        return partial(request, "_open_tasks.html", **open_tasks_ctx())

    @app.post("/tasks/note", response_class=HTMLResponse)
    def open_tasks_note(request: Request, pick: str = Form(...), text: str = Form(...)):
        p, ref, t = _picked(pick)
        ops.add_task_note(p, ref, text)
        return open_done(request, f"Added a note to “{t['text']}”.")

    @app.post("/tasks/photo", response_class=HTMLResponse)
    async def open_tasks_photo(request: Request, pick: str = Form(...), image: UploadFile = File(...),
                               note: str = Form("")):
        p, ref, t = _picked(pick)
        data, ext = await _upload(image)
        ops.add_photo(p, data, ext, note.strip() or None, task=ref)
        return open_done(request, f"Added a photo to “{t['text']}”.")

    @app.post("/tasks/link", response_class=HTMLResponse)
    def open_tasks_link(request: Request, pick: str = Form(...), target: str = Form(...), name: str = Form("")):
        p, ref, t = _picked(pick)
        ops.add_task_file(p, ref, target, name.strip() or None)
        return open_done(request, f"Added a link to “{t['text']}”.")

    @app.post("/tasks/photo/delete", response_class=HTMLResponse)
    def open_tasks_photo_delete(request: Request, pick: str = Form(...), n: int = Form(...)):
        """Deletes photo `n` (1-based) of a task, and its file."""
        p, ref, t = _picked(pick)
        ops.remove_photo(p, str(n), task=ref)
        return open_done(request, f"Deleted a photo from “{t['text']}”.")

    @app.post("/tasks/link/delete", response_class=HTMLResponse)
    def open_tasks_link_delete(request: Request, pick: str = Form(...), n: int = Form(...)):
        """Removes link `n` (1-based) of a task; a linked file itself is not touched."""
        p, ref, t = _picked(pick)
        f = ops.remove_task_file(p, ref, str(n))
        return open_done(request, f"Removed “{f['name']}” from “{t['text']}”.")

    @app.post("/tasks/remind", response_class=HTMLResponse)
    def open_tasks_remind(request: Request, pick: str = Form(...), when: str = Form(...), text: str = Form("")):
        p, ref, t = _picked(pick)
        t = reminders.schedule_task_reminder(p, ref, when, text)
        return open_done(request, f"Reminder set for {reminders.reminder_label(t['reminder'])}: “{text.strip() or t['text']}”.")

    @app.get("/tasks", response_class=HTMLResponse)
    def open_tasks_page(request: Request, form: str | None = None, pick: str | None = None):
        if form is not None and (form not in OPEN_FORMS or not pick):
            raise HTTPException(400, f"bad form {form!r}")
        return page(request, "tasks.html", nav="tasks", **open_tasks_ctx(form=form, pick=pick))

    @app.post("/tasks/today", response_class=HTMLResponse)
    async def open_tasks_to_today(request: Request):
        """Copies the checked tasks (`pick` = "<project folder>:<task number>") into Today."""
        form = await request.form()
        picks = [_pick(v) for v in form.getlist("pick")]
        loaded: dict[str, Project] = {}           # one Project per folder, so its ids accumulate
        pairs = [(loaded.setdefault(f, get_project(f)), i) for f, i in picks]
        added = ops.copy_many_to_today(ws, pairs)
        return partial(request, "_open_tasks.html", **open_tasks_ctx(copied=added, skipped=len(pairs) - added))

    @app.post("/today/clear")
    def today_clear(request: Request):
        ops.clear_today_done(ws)
        return tasks_partial(request, ops.ensure_today(ws))

    def _project_ctx(p: Project) -> dict:
        return dict(p=p, url=purl(p), card=card(p), areas=ws.areas(), closed=ws.is_in_closed(p),
                    notes=list(reversed(p.notes)), today=dt.date.today().isoformat(),
                    files=files_info(p.files), file_edit=None,
                    task_files=[files_info(t["files"]) for t in p.tasks], task_attach=None,
                    task_note_add=None, task_note_edit=None, task_photo_add=None,
                    photo_url=lambda path: f"{purl(p)}/photo/{quote(path.split('/', 1)[1], safe='')}",
                    **_today_ctx(p))

    def _today_ctx(p: Project) -> dict:
        """Today links: on Today, each task's source project; elsewhere, which tasks are in Today,
        plus the project's archived tasks."""
        if ws.is_today(p):
            src = ops.today_sources(ws)

            def label(tid):
                if tid not in src:
                    return None
                title, q = src[tid]
                return dict(title=title, url=purl(q) if q else "/archive")
            return dict(is_today=True, in_today=set(), task_source=[label(t["id"]) for t in p.tasks], archived=[])
        gone = [] if ws.is_archive(p) else ops.archived_tasks(ws, project=p.folder_name)
        return dict(is_today=False, in_today=ops.today_ids(ws), task_source=[None] * len(p.tasks),
                    archived=[dict(n=i + 1, t=t) for i, t in gone])

    # ---- Archive -------------------------------------------------------------
    ARCHIVE_SINCE = {"7": "Last 7 days", "30": "Last 30 days", "90": "Last 3 months", "365": "Last year"}
    ARCHIVE_SORTS = {"newest": "Newest first", "oldest": "Oldest first", "name": "A–Z", "project": "By project"}

    @app.get("/archive", response_class=HTMLResponse)
    def archive_page(request: Request, project: str = "", since: str = "", sort: str = "newest"):
        sort = sort if sort in ARCHIVE_SORTS else "newest"
        since = since if since in ARCHIVE_SINCE else ""
        cutoff = dt.date.today() - dt.timedelta(days=int(since)) if since else None
        a = ws.archive()
        names = ops.archive_projects(ws)
        project = next((n for n in names if n.lower() == project.lower()), project)   # unknown: matches nothing
        items = ops.archived_tasks(ws, project or None, cutoff, sort)
        existing = {q.folder_name.lower(): q for q in ws.projects()}
        rows = []
        for i, t in items:
            q = existing.get((t["from"] or "").lower())
            rows.append(dict(n=i + 1, t=t, files=files_info(t["files"]),
                             project_url=purl(q) if q else None, project_closed=bool(q and ws.is_in_closed(q))))
        return page(request, "archive.html", nav="archive", rows=rows, names=names, project=project,
                    since=since, sort=sort, since_opts=ARCHIVE_SINCE, sort_opts=ARCHIVE_SORTS,
                    total=len(a.tasks) if a else 0, aurl=f"/p/{quote(ARCHIVE_DIR, safe='')}")

    def _refresh() -> Response:
        return Response(status_code=204, headers={"HX-Refresh": "true"})

    @app.post("/archive/{n}/restore")
    def archive_restore(n: int):
        ops.restore_task(ws, str(n))
        return _refresh()

    @app.post("/archive/{n}/delete")
    def archive_delete(n: int):
        a = ws.archive()
        if a is None:
            raise ops.OpError("the Archive is empty")
        ops.remove_task(a, str(n))
        return _refresh()

    def files_info(entries: list[dict]) -> list[dict]:
        """Link entries plus whether the file exists and its full path (for display)."""
        out = []
        for f in entries:
            exists, full = True, f["target"]
            if f["kind"] == "file":
                try:
                    path = ops.resolve_file(f["target"])
                    exists, full = path.exists(), str(path)
                except ops.OpError:
                    exists = False
            out.append({**f, "exists": exists, "full": full})
        return out

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

    # ---- tasks (## Tasks checklist in the README body) ---------------------
    def tasks_partial(request: Request, p: Project, editing: int | None = None, attach: int | None = None,
                      note: int | None = None, note_edit: tuple[int, int] | None = None,
                      archived_open: bool = False, photo: int | None = None, move: int | None = None,
                      moved: dict | None = None, remind: int | None = None):
        tomorrow = (dt.datetime.now() + dt.timedelta(days=1)).replace(hour=9, minute=0)
        return partial(request, "_tasks.html", **{**_project_ctx(Project.load(p.dir)),
                                                  "task_remind": remind, "remind_default": tomorrow.strftime("%Y-%m-%dT%H:%M"),
                                                  "reminder_list": reminders.REMINDER_LIST,
                                                  "task_edit": editing, "task_attach": attach,
                                                  "task_note_add": note, "task_note_edit": note_edit,
                                                  "archived_open": archived_open, "task_photo_add": photo,
                                                  "task_move": move, "move_targets": move_targets(p) if move else [],
                                                  "task_moved": moved})

    def move_targets(p: Project) -> list[dict]:
        """Projects a task of `p` can move to, by area in overview order; closed ones last."""
        ov = ops.overview(ws)
        groups, closed = [], []
        for area in ops.overview_areas(ws, ov):
            open_, shut = [], []
            for q in ops.area_projects(ws, area, ov):
                if q.dir == p.dir or q.legacy or q.parse_error:
                    continue
                (shut if q.status == "closed" else open_).append(q)
            if open_:
                groups.append(dict(label=area, projects=open_))
            closed += shut
        if closed:
            groups.append(dict(label="Closed", projects=sorted(closed, key=lambda q: q.title.casefold())))
        return groups

    # ---- photos (project "## Photos" and task photos; files in the project's Photos/ folder) ----
    MAX_PHOTO = 60 * 1024 * 1024

    async def _upload(image: UploadFile) -> tuple[bytes, str]:
        data = await image.read(MAX_PHOTO + 1)
        if len(data) > MAX_PHOTO:
            raise HTTPException(413, "That photo is larger than 60 MB.")
        return data, Path(image.filename or "photo.jpg").suffix or ".jpg"

    def photos_partial(request: Request, p: Project):
        return partial(request, "_photos.html", **_project_ctx(Project.load(p.dir)))

    @app.get("/p/{key}/photo/{name}")
    def photo_file(key: str, name: str):
        p = get_project(key)
        if "/" in name or "\\" in name or name.startswith("."):
            raise HTTPException(404)
        f = ops.photo_path(p, f"{ops.PHOTO_DIR}/{name}")
        if not f.is_file():
            raise HTTPException(404, "photo file not found")
        return FileResponse(f, headers={"Cache-Control": "private, max-age=86400"})

    @app.post("/p/{key}/photos", response_class=HTMLResponse)
    async def photo_add(request: Request, key: str, image: UploadFile = File(...), note: str = Form("")):
        p = get_project(key)
        data, ext = await _upload(image)
        ops.add_photo(p, data, ext, note)
        return photos_partial(request, p)

    @app.post("/p/{key}/photos/{n}/note", response_class=HTMLResponse)
    def photo_note(request: Request, key: str, n: int, note: str = Form("")):
        p = get_project(key)
        ops.edit_photo_note(p, str(n), note)
        return photos_partial(request, p)

    @app.post("/p/{key}/photos/{n}/delete", response_class=HTMLResponse)
    def photo_delete(request: Request, key: str, n: int):
        p = get_project(key)
        ops.remove_photo(p, str(n))
        return photos_partial(request, p)

    @app.post("/p/{key}/tasks/{t}/photos", response_class=HTMLResponse)
    async def task_photo_add(request: Request, key: str, t: int, image: UploadFile = File(...), note: str = Form("")):
        p = get_project(key)
        data, ext = await _upload(image)
        ops.add_photo(p, data, ext, note, task=str(t))
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{t}/photos/{n}/note", response_class=HTMLResponse)
    def task_photo_note(request: Request, key: str, t: int, n: int, note: str = Form("")):
        p = get_project(key)
        ops.edit_photo_note(p, str(n), note, task=str(t))
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{t}/photos/{n}/delete", response_class=HTMLResponse)
    def task_photo_delete(request: Request, key: str, t: int, n: int):
        p = get_project(key)
        ops.remove_photo(p, str(n), task=str(t))
        return tasks_partial(request, p)

    @app.get("/p/{key}/tasks", response_class=HTMLResponse)
    def tasks_view(request: Request, key: str, edit: int | None = None, attach: int | None = None,
                   note: int | None = None, note_edit: str | None = None, photo: int | None = None,
                   move: int | None = None, remind: int | None = None):
        ne = None
        if note_edit:                      # "task.note", both 1-based
            try:
                ne = tuple(int(x) for x in note_edit.split(".", 1))
            except ValueError:
                raise HTTPException(400, "note_edit must look like 2.1")
        return tasks_partial(request, get_project(key), edit, attach, note, ne, photo=photo, move=move, remind=remind)

    # task notes: indented "  - text" lines under a task
    @app.post("/p/{key}/tasks/{n}/notes")
    def task_note_add(request: Request, key: str, n: int, text: str = Form(...)):
        p = get_project(key)
        ops.add_task_note(p, str(n), text)
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/notes/{m}/edit")
    def task_note_edit(request: Request, key: str, n: int, m: int, text: str = Form(...)):
        p = get_project(key)
        ops.edit_task_note(p, str(n), str(m), text)
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/notes/{m}/delete")
    def task_note_delete(request: Request, key: str, n: int, m: int):
        p = get_project(key)
        ops.remove_task_note(p, str(n), str(m))
        return tasks_partial(request, p)

    # task attachments: links to files under ~/Documents or URLs (referenced, never copied)
    @app.post("/p/{key}/tasks/{n}/files")
    def task_file_add(request: Request, key: str, n: int, target: str = Form(...), name: str = Form("")):
        p = get_project(key)
        ops.add_task_file(p, str(n), target, name.strip() or None)
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/files/{m}/delete")
    def task_file_delete(request: Request, key: str, n: int, m: int):
        p = get_project(key)
        ops.remove_task_file(p, str(n), str(m))
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/files/{m}/open")
    def task_file_open(key: str, n: int, m: int):
        p = get_project(key)
        tasks = p.tasks
        if not 0 < n <= len(tasks) or not 0 < m <= len(tasks[n - 1]["files"]):
            raise ops.OpError(f"no attachment #{m} on task #{n}")
        ops.open_file_entry(tasks[n - 1]["files"][m - 1])
        return Response(status_code=204)

    @app.post("/p/{key}/tasks")
    def task_add(request: Request, key: str, text: str = Form(...)):
        p = get_project(key)
        if text.strip():
            ops.add_task(p, text)
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/toggle")
    def task_toggle(request: Request, key: str, n: int):
        p = get_project(key)
        tasks, before = p.tasks, p.status
        ops.set_task(p, str(n), not tasks[n - 1]["done"] if 0 < n <= len(tasks) else True, ws)
        if p.status != before:           # last task ticked: now Completed – On Hold; reload to show it
            return Response(status_code=204, headers={"HX-Refresh": "true"})
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/today")
    def task_copy_today(request: Request, key: str, n: int):
        p = get_project(key)
        ops.copy_to_today(ws, p, str(n))
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/remind")
    def task_remind(request: Request, key: str, n: int, text: str = Form(""), when: str = Form(...)):
        """Creates an Apple Reminder (Reminders › Projects Tasks) and records it in the task."""
        p = get_project(key)
        reminders.schedule_task_reminder(p, str(n), when, text)
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/reminder/clear")
    def task_reminder_clear(request: Request, key: str, n: int):
        p = get_project(key)
        ops.set_task_reminder(p, str(n), None)
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/archive")
    def task_archive(request: Request, key: str, n: int):
        p = get_project(key)
        ops.archive_task(ws, p, str(n))
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/move-to")
    def task_move_to(request: Request, key: str, n: int, to: str = Form(...)):
        p = get_project(key)
        dest = get_project(to)
        t = ops.move_task_to(ws, p, str(n), dest)
        return tasks_partial(request, p, moved=dict(text=t["text"], title=dest.title, url=purl(dest)))

    @app.post("/p/{key}/archived/{n}/restore")
    def task_restore(request: Request, key: str, n: int):
        p = get_project(key)
        ops.restore_task(ws, str(n))
        return tasks_partial(request, p, archived_open=True)

    @app.post("/p/{key}/tasks/{n}/edit")
    def task_edit(request: Request, key: str, n: int, text: str = Form(...)):
        p = get_project(key)
        ops.edit_task(p, str(n), text)
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/move")
    def task_move(request: Request, key: str, n: int, to: int = Form(...)):
        p = get_project(key)
        ops.move_task(p, str(n), to)
        return tasks_partial(request, p)

    @app.post("/p/{key}/tasks/{n}/delete")
    def task_delete(request: Request, key: str, n: int):
        p = get_project(key)
        ops.remove_task(p, str(n))
        return tasks_partial(request, p)

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
    def receipt_add(request: Request, key: str, target: str = Form(...),
                    amount: str = Form(""), vendor: str = Form(""), date: str = Form("")):
        """Reference an existing file by path (never copied: the file is the source of truth)."""
        p = get_project(key)
        try:
            amt = float(amount.replace("$", "").replace(",", "")) if amount.strip() else None
            d = dt.date.fromisoformat(date) if date else None
        except ValueError as e:
            raise ops.OpError(f"invalid amount or date: {e}")
        t = target.strip().strip('"').strip("'")
        src = Path.home() / t if t.startswith("Documents/") else Path(t).expanduser()
        ops.add_receipt(ws, p, src, amt, vendor.strip() or None, d)
        return partial(request, "_receipts.html", **_project_ctx(Project.load(p.dir)))

    @app.post("/p/{key}/receipts/upload")
    async def receipt_upload(request: Request, key: str, image: UploadFile = File(...), description: str = Form(""),
                             amount: str = Form(""), vendor: str = Form(""), date: str = Form("")):
        """A new receipt with no other original (a photo from Photos, a scan): saved into the receipts
        folder as <year>/<date> <description>.<ext>, the same as the apps do."""
        p = get_project(key)
        try:
            amt = float(amount.replace("$", "").replace(",", "")) if amount.strip() else None
            d = dt.date.fromisoformat(date) if date else None
        except ValueError as e:
            raise ops.OpError(f"invalid amount or date: {e}")
        data, ext = await _upload(image)
        if ext.lower() not in ops.PHOTO_EXTS | {".pdf"}:
            raise ops.OpError(f"not an image or PDF: {image.filename}")
        ops.save_receipt(ws, p, data, ext, description, amt, vendor, d)
        return partial(request, "_receipts.html", **_project_ctx(Project.load(p.dir)))

    @app.post("/p/{key}/receipts/{n}/delete")
    def receipt_delete(request: Request, key: str, n: int):
        p = get_project(key)
        ops.remove_receipt(p, n - 1)
        return partial(request, "_receipts.html", **_project_ctx(Project.load(p.dir)))

    @app.get("/p/{key}/receipts/{n}")
    def receipt_file(key: str, n: int):
        """Serve a receipt the project references (only paths listed in its README)."""
        rec = get_project(key).receipts
        if not 0 < n <= len(rec):
            raise HTTPException(404)
        try:
            f = ops.receipt_target(ws, str(rec[n - 1].get("path", "")))
        except ops.OpError:
            raise HTTPException(404)
        if not f.is_file():
            raise HTTPException(404)
        return FileResponse(f, content_disposition_type="inline", filename=f.name)

    @app.get("/p/{key}/section/{name}", response_class=HTMLResponse)
    def section_view(request: Request, key: str, name: str, edit: bool = False):
        p = get_project(key)
        if name == "Project Files" and not edit:
            return files_partial(request, p)
        return partial(request, "_section.html", **_project_ctx(p), name=name,
                       text=p.section(name) or "", edit=edit)

    @app.post("/p/{key}/section/{name}", response_class=HTMLResponse)
    def section_save(request: Request, key: str, name: str, text: str = Form("")):
        p = get_project(key)
        ops.set_section(p, name, text)
        p = Project.load(p.dir)
        if name == "Project Files":
            return files_partial(request, p)
        return partial(request, "_section.html", **_project_ctx(p), name=name,
                       text=p.section(name) or "", edit=False)

    # ---- project files (named links to ~/Documents files or URLs) ------------
    def files_partial(request: Request, p: Project, editing: int | None = None):
        return partial(request, "_files.html", **{**_project_ctx(Project.load(p.dir)), "file_edit": editing})

    @app.get("/p/{key}/files", response_class=HTMLResponse)
    def files_view(request: Request, key: str, edit: int | None = None):
        return files_partial(request, get_project(key), edit)

    @app.post("/p/{key}/files")
    def file_add(request: Request, key: str, target: str = Form(...), name: str = Form("")):
        p = get_project(key)
        ops.add_file(p, target, name.strip() or None)
        return files_partial(request, p)

    @app.post("/p/{key}/files/{n}/edit")
    def file_edit(request: Request, key: str, n: int, target: str = Form(...), name: str = Form("")):
        p = get_project(key)
        ops.edit_file(p, str(n), name.strip() or "", target)
        return files_partial(request, p)

    @app.post("/p/{key}/files/{n}/delete")
    def file_delete(request: Request, key: str, n: int):
        p = get_project(key)
        ops.remove_file(p, str(n))
        return files_partial(request, p)

    @app.post("/p/{key}/files/{n}/open")
    def file_open(key: str, n: int):
        p = get_project(key)
        files = p.files
        if not 0 < n <= len(files):
            raise ops.OpError(f"no project file #{n}")
        ops.open_file_entry(files[n - 1])
        return Response(status_code=204)

    @app.get("/browse", response_class=HTMLResponse)
    def browse(request: Request, path: str = "Documents"):
        """Folder listing under ~/Documents for picking a Project Files target."""
        rel = ops.check_file_target(path) if path != "Documents" else "Documents"
        home = Path.home().resolve()
        d = (home / rel).resolve()
        if not d.is_relative_to(home / "Documents") or not d.is_dir():
            raise HTTPException(404)
        entries = []
        try:
            for c in sorted(d.iterdir(), key=lambda c: (not c.is_dir(), c.name.lower())):
                name = c.name
                if name.startswith(".") and name.endswith(".icloud"):   # evicted iCloud file
                    name = name[1:-7]
                elif name.startswith("."):
                    continue
                is_dir = c.is_dir() and c.suffix.lower() not in PACKAGE_SUFFIXES
                entries.append(dict(name=name, rel=f"{rel}/{name}", is_dir=is_dir))
        except PermissionError:
            raise ops.OpError(f"cannot read {rel}")
        parts = rel.split("/")
        crumbs = [dict(name=parts[i], rel="/".join(parts[:i + 1])) for i in range(len(parts))]
        return partial(request, "_browse.html", entries=entries, crumbs=crumbs, rel=rel)

    @app.post("/p/{key}/status")
    def status_set(request: Request, key: str, status: str = Form(...)):
        p = get_project(key)
        ops.set_status(p, status)
        return redirect(purl(p))

    @app.post("/p/{key}/close")
    def close(key: str):
        return redirect(purl(ops.close(ws, get_project(key))))

    @app.post("/p/{key}/reopen")
    def reopen(key: str, area: str = Form(""), stay: int = Form(0)):
        p = ops.reopen(ws, get_project(key), area or None)
        return _refresh() if stay else redirect(purl(p))      # stay: reopened from a tile on the overview

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
                            tasks_done=p.task_progress[0], tasks_total=p.task_progress[1],
                            cost=p.total_cost, path=str(p.dir)))
        return JSONResponse(out)

    return app
