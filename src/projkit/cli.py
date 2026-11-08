"""`proj` command line."""
from __future__ import annotations

import datetime as dt
import logging
import os
import re
import shlex
import subprocess
from pathlib import Path
from typing import Optional

import typer
from rich.console import Console
from rich.markdown import Markdown
from rich.table import Table

from . import ops, reminders
from .lint import lint_workspace
from .project import Project, status_label
from .workspace import Workspace

app = typer.Typer(no_args_is_help=True, help="Manage projects in ~/Documents/Projects.")
console = Console()


def _show_version(value: bool) -> None:
    if value:
        from .about import version_string
        console.print(f"proj {version_string()}", highlight=False)
        raise typer.Exit()


@app.callback()
def _main(version: bool = typer.Option(False, "--version", "-V", callback=_show_version, is_eager=True,
                                       help="Show the version and exit.")):
    """Manage projects in ~/Documents/Projects."""


def _ws(root: Optional[Path], receipts: Optional[Path]) -> Workspace:
    ws = Workspace.default()
    if root:
        ws.root = root.expanduser()
    if receipts:
        ws.receipts_root = receipts.expanduser()
    return ws


RootOpt = typer.Option(None, "--root", envvar="PROJ_ROOT", help="Projects root")
ReceiptsOpt = typer.Option(None, "--receipts", envvar="PROJ_RECEIPTS", help="Receipts root")


def _pick(ws: Workspace, query: str) -> Project:
    hits = ws.find(query)
    if not hits:
        console.print(f"[red]No project matches '{query}'.[/]")
        raise typer.Exit(1)
    if len(hits) > 1:
        console.print(f"[yellow]'{query}' matches several projects:[/]")
        for p in hits:
            console.print(f"  • {p.dir.parent.name} / {p.folder_name}")
        raise typer.Exit(1)
    return hits[0]


@app.command("ls")
def ls(area: Optional[str] = typer.Option(None, "--area", "-a"),
       status: Optional[str] = typer.Option(None, "--status", "-s"),
       closed: bool = typer.Option(False, "--closed", help="Include closed projects"),
       root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """List projects."""
    ws = _ws(root, receipts)
    t = Table(box=None, header_style="bold")
    for col in ("Area", "Project", "Status", "Goals", "Tasks", "Cost"):
        t.add_column(col, justify="right" if col in ("Goals", "Tasks", "Cost") else "left")
    ov = ops.overview(ws)
    projs = ws.projects(include_closed=closed or status == "closed")
    groups: dict[str, list[Project]] = {a: [] for a in ws.areas()}
    for p in projs:
        groups.setdefault(ops.project_area(ws, p), []).append(p)
    for a in ops.sort_areas(ov, list(groups)):
        for p in ops.sort_projects(ov, a, groups[a]):
            if area and area.lower() not in a.lower():
                continue
            st = "legacy" if p.legacy else p.status
            if status and st != status:
                continue
            done, total = p.goal_progress
            tdone, ttotal = p.task_progress
            t.add_row(a, p.title, status_label(st), f"{done}/{total}" if total else "", f"{tdone}/{ttotal}" if ttotal else "",
                      f"${p.total_cost:,.2f}" if p.receipts else "")
    console.print(t)


@app.command()
def show(project: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Show one project."""
    p = _pick(_ws(root, receipts), project)
    console.print(f"[bold]{p.title}[/]  [dim]{p.dir}[/]")
    if p.legacy:
        console.print("[yellow]No README.md yet — run `proj migrate`.[/]")
        return
    console.print(f"area: {p.area}   status: {status_label(p.status)}   created: {p.created or '—'}")
    if p.goals:
        console.print("\n[bold]Goals[/]")
        for g in p.goals:
            console.print(f"  {'[green]✔[/]' if g.get('done') else '☐'} {g.get('text')}")
    if p.links:
        console.print("\n[bold]Links[/]")
        for l in p.links:
            console.print(f"  • {l.get('title') or l.get('url')}  [dim]{l.get('url')}[/]")
    if p.receipts:
        console.print(f"\n[bold]Receipts[/]  total ${p.total_cost:,.2f}")
        for r in p.receipts:
            console.print(f"  • {r.get('date') or ''} {r.get('vendor') or ''} {r.get('amount') or ''}  [dim]{r.get('path')}[/]")
    console.print()
    console.print(Markdown(p.body))


@app.command()
def lint(fix: bool = typer.Option(False, "--fix", help="Apply safe automatic fixes"),
         root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Check the projects tree for structural problems."""
    ws = _ws(root, receipts)
    issues = lint_workspace(ws)
    colors = {"error": "red", "warn": "yellow", "info": "blue"}
    for i in issues:
        rel = i.path.relative_to(ws.root) if i.path.is_relative_to(ws.root) else i.path
        tag = " [dim](fixable)[/]" if i.fixable and not fix else ""
        console.print(f"[{colors[i.severity]}]{i.code} {i.severity:5}[/] {rel}: {i.message}{tag}")
        if fix and i.fix:
            try:
                console.print(f"        [green]fixed:[/] {i.fix()}")
            except OSError as e:
                console.print(f"        [red]fix failed:[/] {e}")
    errors = sum(i.severity == "error" for i in issues)
    console.print(f"\n{len(issues)} issue(s), {errors} error(s)")
    raise typer.Exit(1 if errors and not fix else 0)


# ---------------------------------------------------------------------------
# Phase 2: migration + mutating commands
# ---------------------------------------------------------------------------
def _fail(msg: str):
    console.print(f"[red]{msg}[/]")
    raise typer.Exit(1)


def _run(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except (ops.OpError, reminders.ReminderError) as e:
        console.print(f"[red]{e}[/]")
        raise typer.Exit(1)


@app.command()
def migrate(dry_run: bool = typer.Option(False, "--dry-run", "-n", help="Print the generated READMEs only"),
            only: Optional[str] = typer.Option(None, "--only", help="Migrate just this project folder name"),
            root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Convert Readme.pages → README.md (also the template and the idea backlog). Uses Pages."""
    from . import migrate as mg
    from .project import join_front_matter
    from .workspace import BACKLOG_STEM

    logging.getLogger("pypdf").setLevel(logging.ERROR)
    ws = _ws(root, receipts)
    jobs: list[tuple[Path, str, str]] = []  # (dir, title, area)
    if ws.template_dir.is_dir():
        jobs.append((ws.template_dir, "Project", "Area"))
    for p in ws.projects():
        jobs.append((p.dir, p.folder_name, ws.location_area(p) or p.area or ""))
    if only:
        jobs = [j for j in jobs if j[0].name.lower() == only.lower()]

    done = 0
    for d, title, area in jobs:
        pages = mg.legacy_readme(d)
        if (d / "README.md").exists() or pages is None:
            continue
        console.rule(f"{d.parent.name} / {d.name}")
        try:
            res = mg.convert(pages, title, area)
        except RuntimeError as e:
            console.print(f"[red]{e}[/]")
            continue
        if ws.is_in_closed(Project(dir=d)):
            res.meta["status"] = "closed"
        for line in res.report:
            console.print(f"  [cyan]•[/] {line}")
        if dry_run:
            console.print(join_front_matter(res.meta, res.body), markup=False, highlight=False)
        else:
            legacy = mg.write_project(d, res, pages)
            console.print(f"  [green]wrote README.md[/], kept original as {legacy.name}")
        done += 1

    backlog = ws.root / f"{BACKLOG_STEM}.pages"
    backlog_md = ops.backlog_path(ws)
    if backlog.exists() and not backlog_md.exists() and not only:
        console.rule("Idea backlog")
        text = mg.convert_backlog(backlog)
        console.print(text, markup=False)
        if not dry_run:
            backlog_md.write_text(text, encoding="utf-8")
            backlog.rename(backlog.with_name(f"{BACKLOG_STEM}.legacy.pages"))
            console.print(f"  [green]wrote {backlog_md.name}[/]")
        done += 1
    console.print(f"\n{done} file(s) {'would be ' if dry_run else ''}migrated.")


@app.command()
def new(title: str, area: str = typer.Option(..., "--area", "-a"),
        status: str = typer.Option("active", "--status", "-s"),
        root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Create a project from the template."""
    p = _run(ops.new_project, _ws(root, receipts), title, area, status)
    console.print(f"[green]created[/] {p.dir}")


@app.command("open")
def open_(project: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Reveal the project folder in Finder."""
    subprocess.run(["open", str(_pick(_ws(root, receipts), project).dir)])


@app.command()
def edit(project: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Open README.md in $EDITOR."""
    p = _pick(_ws(root, receipts), project)
    subprocess.run([*shlex.split(os.environ.get("EDITOR", "vi")), str(p.readme)])


@app.command()
def note(project: str, text: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Add a note under today's date."""
    p = _pick(_ws(root, receipts), project)
    _run(ops.add_note, p, text)
    console.print(f"[green]noted[/] in {p.title}")


@app.command()
def status(project: str, value: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Set status: idea | backlog | active | blocked | on-hold | completed-on-hold (use close/reopen for closed)."""
    p = _pick(_ws(root, receipts), project)
    _run(ops.set_status, p, value)
    console.print(f"{p.title}: {value}")


@app.command()
def rename(project: str, new_title: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Rename a project (folder and title)."""
    ws = _ws(root, receipts)
    p = _run(ops.rename, ws, _pick(ws, project), new_title)
    console.print(f"[green]renamed[/] → {p.dir}")


@app.command()
def close(project: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Close a project (moves it to '2 - Closed', keeps its area)."""
    ws = _ws(root, receipts)
    p = _run(ops.close, ws, _pick(ws, project))
    console.print(f"[green]closed[/] → {p.dir}")


@app.command()
def reopen(project: str, area: Optional[str] = typer.Option(None, "--area", "-a"),
           root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Reopen a closed project into its original (or given) area."""
    ws = _ws(root, receipts)
    p = _run(ops.reopen, ws, _pick(ws, project), area)
    console.print(f"[green]reopened[/] → {p.dir}")


goal_app = typer.Typer(no_args_is_help=True, help="Manage goals (refer to a goal by number or text).")
app.add_typer(goal_app, name="goal")


@goal_app.command("add")
def goal_add(project: str, text: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    p = _pick(_ws(root, receipts), project)
    _run(ops.add_goal, p, text)
    console.print(f"[green]added goal #{len(p.goals)}[/] to {p.title}")


@goal_app.command("done")
def goal_done(project: str, goal: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    g = _run(ops.set_goal, _pick(_ws(root, receipts), project), goal, True)
    console.print(f"[green]✔[/] {g['text']}")


@goal_app.command("undo")
def goal_undo(project: str, goal: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    g = _run(ops.set_goal, _pick(_ws(root, receipts), project), goal, False)
    console.print(f"☐ {g['text']}")


@goal_app.command("rm")
def goal_rm(project: str, goal: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    g = _run(ops.remove_goal, _pick(_ws(root, receipts), project), goal)
    console.print(f"removed: {g['text']}")


task_app = typer.Typer(no_args_is_help=True, help="Manage the Tasks checklist (refer to a task by number or text).")
app.add_typer(task_app, name="task")


def _print_task_details(t: dict) -> None:
    for j, n in enumerate(t["notes"], 1):
        console.print(f"       {j}. [dim]—[/] {n}", highlight=False)
    for j, f in enumerate(t["files"], 1):
        icon = "🔗" if f["kind"] == "url" else "📄"
        console.print(f"       {j}. {icon} {f['name']}  [dim]{f['target']}[/]", highlight=False)


@task_app.command("ls")
def task_ls(project: str,
            archived: bool = typer.Option(False, "--archived", "-A", help="Also list this project's archived tasks"),
            root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    ws = _ws(root, receipts)
    p = _pick(ws, project)
    in_today = ops.today_ids(ws)
    for i, t in enumerate(p.tasks, 1):
        sun = "  [yellow]☀ in Today[/]" if t["id"] in in_today else ""
        bell = f"  [cyan]⏰ {reminders.reminder_label(t['reminder'])}[/]" if t["reminder"] else ""
        console.print(f"{i:3}. {'[green]✔[/]' if t['done'] else '☐'} {t['text']}{sun}{bell}", highlight=False)
        _print_task_details(t)
    if not p.tasks:
        console.print("[dim]No tasks.[/]")
    gone = ops.archived_tasks(ws, project=p.folder_name)
    if archived and gone:
        console.print("[bold]Archived[/] [dim](restore with `proj archive restore <number>`)[/]")
        for i, t in gone:
            console.print(f"  [dim]#{i + 1:<3}[/] {'[green]✔[/]' if t['done'] else '☐'} [dim]{t['text']}  · {t['archived']}[/]",
                          highlight=False)
    elif gone:
        console.print(f"[dim]{len(gone)} archived task{'s' if len(gone) != 1 else ''} (show with --archived)[/]")


@task_app.command("add")
def task_add(project: str, text: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    p = _pick(_ws(root, receipts), project)
    _run(ops.add_task, p, text)
    console.print(f"[green]added task #{len(p.tasks)}[/] to {p.title}")


@task_app.command("done")
def task_done(project: str, task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    ws = _ws(root, receipts)
    p = _pick(ws, project)
    before = p.status
    t = _run(ops.set_task, p, task, True, ws)
    console.print(f"[green]✔[/] {t['text']}", highlight=False)
    if p.status != before:
        console.print(f"All tasks done: {p.title} is now {status_label(p.status)}", highlight=False)


@task_app.command("undo")
def task_undo(project: str, task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    ws = _ws(root, receipts)
    t = _run(ops.set_task, _pick(ws, project), task, False, ws)
    console.print(f"☐ {t['text']}", highlight=False)


@task_app.command("edit")
def task_edit(project: str, task: str, text: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    t = _run(ops.edit_task, _pick(_ws(root, receipts), project), task, text)
    console.print(f"edited: {t['text']}", highlight=False)


@task_app.command("mv")
def task_mv(project: str, task: str, position: int,
            root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Move a task to a 1-based position (1 = top)."""
    p = _pick(_ws(root, receipts), project)
    t = _run(ops.move_task, p, task, position)
    console.print(f"moved to #{max(1, min(position, len(p.tasks)))}: {t['text']}", highlight=False)


@task_app.command("rm")
def task_rm(project: str, task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    t = _run(ops.remove_task, _pick(_ws(root, receipts), project), task)
    console.print(f"removed: {t['text']}", highlight=False)


@task_app.command("note")
def task_note(project: str, task: str, text: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Add a note to a task (shown indented below it)."""
    n = _run(ops.add_task_note, _pick(_ws(root, receipts), project), task, text)
    console.print(f"[green]noted[/] {n}", highlight=False)


@task_app.command("note-edit")
def task_note_edit(project: str, task: str, note: str, text: str,
                   root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Replace a task's note (by number or text)."""
    n = _run(ops.edit_task_note, _pick(_ws(root, receipts), project), task, note, text)
    console.print(f"edited: {n}", highlight=False)


@task_app.command("note-rm")
def task_note_rm(project: str, task: str, note: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Delete a task's note (by number or text)."""
    n = _run(ops.remove_task_note, _pick(_ws(root, receipts), project), task, note)
    console.print(f"deleted note: {n}", highlight=False)


@task_app.command("today")
def task_today(project: str, task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Copy a task into the Today list (ticking either copy ticks both)."""
    ws = _ws(root, receipts)
    t, added = _run(ops.copy_to_today, ws, _pick(ws, project), task)
    console.print(f"[green]copied to Today:[/] {t['text']}" if added else f"already in Today: {t['text']}", highlight=False)


@task_app.command("remind")
def task_remind(project: str, task: str,
                when: str = typer.Argument(..., metavar="WHEN", help='Date and time, "YYYY-MM-DD HH:MM" (a date alone means 09:00)'),
                text: Optional[str] = typer.Option(None, "--text", "-t", help="Reminder text (default: the task's text)"),
                clear: bool = typer.Option(False, "--clear", help="Only forget the recorded reminder (WHEN is ignored)"),
                root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Create an Apple Reminder for a task in the 'Projects Tasks' list, and record it in the task."""
    p = _pick(_ws(root, receipts), project)
    if clear:
        t = _run(ops.set_task_reminder, p, task, None)
        console.print(f"cleared reminder: {t['text']}", highlight=False)
        return
    t = _run(reminders.schedule_task_reminder, p, task, when, text)
    console.print(f"[green]⏰ reminder set[/] for {reminders.reminder_label(t['reminder'])}: {text or t['text']}  "
                  f"[dim](Reminders › {reminders.REMINDER_LIST})[/]", highlight=False)


@task_app.command("archive")
def task_archive(project: str, task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Move a task (with its notes and attachments) to the Archive."""
    ws = _ws(root, receipts)
    p = _pick(ws, project)
    t = _run(ops.archive_task, ws, p, task)
    console.print(f"[green]archived[/] {t['text']}  [dim]from {t['from']}[/]", highlight=False)


@task_app.command("move-to")
def task_move_to(project: str, task: str, to_project: str = typer.Argument(..., metavar="TO_PROJECT"),
                 root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Move a task (with its notes, attachments and photos) to the end of another project's tasks."""
    ws = _ws(root, receipts)
    p, dest = _pick(ws, project), _pick(ws, to_project)
    t = _run(ops.move_task_to, ws, p, task, dest)
    console.print(f"[green]moved to {dest.title}:[/] {t['text']}", highlight=False)


@task_app.command("attach")
def task_attach(project: str, task: str, target: str,
                name: Optional[str] = typer.Option(None, "--name", "-n", help="Friendly name (default: file name or website)"),
                root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Attach a file under ~/Documents or a URL to a task (linked by path; nothing is copied)."""
    f = _run(ops.add_task_file, _pick(_ws(root, receipts), project), task, target, name)
    console.print(f"[green]attached[/] {f['name']}  [dim]{f['target']}[/]", highlight=False)


@task_app.command("detach")
def task_detach(project: str, task: str, attachment: str,
                root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Remove an attachment (by number or name) from a task. The file itself is not touched."""
    f = _run(ops.remove_task_file, _pick(_ws(root, receipts), project), task, attachment)
    console.print(f"detached: {f['name']}", highlight=False)


@task_app.command("open")
def task_open(project: str, task: str, attachment: str = typer.Argument("1"),
              root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Open a task's attachment (default: the first) in its default app or browser."""
    p = _pick(_ws(root, receipts), project)
    t = p.tasks[_run(ops._task_index, p, task)]
    _run(ops.open_file_entry, t["files"][_run(ops._task_file_index, t, attachment)])


today_app = typer.Typer(invoke_without_command=True,
                        help="The Today list: tasks to do today (refer to a task by number or text).")
app.add_typer(today_app, name="today")


def _today(ws: Workspace) -> Project:
    return ops.ensure_today(ws)


@today_app.callback()
def today_ls(ctx: typer.Context, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Show the Today list (with each copied task's project)."""
    if ctx.invoked_subcommand:
        return
    ws = _ws(root, receipts)
    t = ws.today()
    tasks = t.tasks if t else []
    src = ops.today_sources(ws)
    for i, x in enumerate(tasks, 1):
        from_ = f"  [dim]· {src[x['id']][0]}[/]" if x["id"] in src else ""
        console.print(f"{i:3}. {'[green]✔[/]' if x['done'] else '☐'} {x['text']}{from_}", highlight=False)
    if not tasks:
        console.print("[dim]Nothing in Today yet. Add with `proj today add` or `proj task today <project> <task>`.[/]")


@today_app.command("add")
def today_add(text: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    t = _today(_ws(root, receipts))
    _run(ops.add_task, t, text)
    console.print(f"[green]added to Today:[/] {text}", highlight=False)


@today_app.command("copy")
def today_copy(project: str, task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Copy a project's task into Today (same as `proj task today`)."""
    task_today(project, task, root, receipts)


@today_app.command("done")
def today_done(task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Tick a Today task (and its original in its project)."""
    ws = _ws(root, receipts)
    t = _run(ops.set_task, _today(ws), task, True, ws)
    console.print(f"[green]✔[/] {t['text']}", highlight=False)


@today_app.command("undo")
def today_undo(task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    ws = _ws(root, receipts)
    t = _run(ops.set_task, _today(ws), task, False, ws)
    console.print(f"☐ {t['text']}", highlight=False)


@today_app.command("rm")
def today_rm(task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Remove a task from Today (its original stays in its project)."""
    t = _run(ops.remove_task, _today(_ws(root, receipts)), task)
    console.print(f"removed from Today: {t['text']}", highlight=False)


@today_app.command("clear")
def today_clear(root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Remove ticked-off tasks from Today (start a fresh day)."""
    n = ops.clear_today_done(_ws(root, receipts))
    console.print(f"cleared {n} done task{'s' if n != 1 else ''} from Today")


tasks_app = typer.Typer(invoke_without_command=True,
                        help="All Open Tasks: every open task of every project that isn't closed, by project.")
app.add_typer(tasks_app, name="tasks")


def _open_numbered(ws: Workspace) -> list[tuple[int, dict, int, dict]]:
    """(number, group, task index, task) for every open task; numbers run across all projects."""
    out, n = [], 0
    for g in ops.open_tasks(ws):
        for i, t in g["tasks"]:
            n += 1
            out.append((n, g, i, t))
    return out


@tasks_app.callback()
def tasks_ls(ctx: typer.Context,
             search: Optional[str] = typer.Option(None, "--search", "-s", help="Only tasks or projects containing this text"),
             area: Optional[str] = typer.Option(None, "--area", "-a", help="Only projects in this area"),
             root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """List all open tasks, grouped by project (copy some to Today with `proj tasks today <n>…`)."""
    if ctx.invoked_subcommand:
        return
    ws = _ws(root, receipts)
    in_today = ops.today_ids(ws)
    q = (search or "").lower()
    shown, last = 0, None
    for n, g, _, t in _open_numbered(ws):
        p = g["project"]
        if area and g["area"].lower() != area.lower():
            continue
        if q and q not in t["text"].lower() and q not in p.title.lower():
            continue
        if last is not p:
            console.print(f"\n[bold]{p.title}[/]  [dim]{g['area']} · {status_label(p.status)}[/]", highlight=False)
            last = p
        sun = "  [yellow]☀ in Today[/]" if t["id"] in in_today else ""
        console.print(f"{n:4}. ☐ {t['text']}{sun}", highlight=False)
        shown += 1
    if not shown:
        console.print("[dim]No open tasks.[/]" if not (q or area) else "[dim]No matching open tasks.[/]")


def _open_row(ws: Workspace, number: int) -> tuple[dict, int, dict]:
    for n, g, i, t in _open_numbered(ws):
        if n == number:
            return g, i, t
    _fail(f"no open task #{number} (see `proj tasks`)")


@tasks_app.command("show")
def tasks_show(number: int = typer.Argument(..., help="Task number from `proj tasks`"),
               root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Open an open task: show it with its project, notes, attachments and reminder."""
    ws = _ws(root, receipts)
    g, i, t = _open_row(ws, number)
    p = g["project"]
    console.print(f"[bold]{p.title}[/]  [dim]{g['area']} · {status_label(p.status)} · task {i + 1} of {len(p.tasks)}[/]",
                  highlight=False)
    sun = "  [yellow]☀ in Today[/]" if t["id"] in ops.today_ids(ws) else ""
    bell = f"  [cyan]⏰ {reminders.reminder_label(t['reminder'])}[/]" if t["reminder"] else ""
    console.print(f"  ☐ {t['text']}{sun}{bell}", highlight=False)
    _print_task_details(t)
    for ph in t["photos"]:
        console.print(f"       📷 {ph['note'] or ph['path']}  [dim]{ph['path']}[/]", highlight=False)
    console.print(f"[dim]Edit: proj tasks edit {number} \"new text\"  ·  more: proj task … \"{p.folder_name}\" {i + 1}[/]",
                  highlight=False)


@tasks_app.command("edit")
def tasks_edit(number: int = typer.Argument(..., help="Task number from `proj tasks`"), text: str = typer.Argument(...),
               root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Change an open task's text (keeps its Today link and reminder)."""
    ws = _ws(root, receipts)
    g, i, _ = _open_row(ws, number)
    t = _run(ops.edit_task, g["project"], str(i + 1), text)
    console.print(f"edited: {t['text']}  [dim]· {g['project'].title}[/]", highlight=False)


@tasks_app.command("note")
def tasks_note(number: int = typer.Argument(..., help="Task number from `proj tasks`"), text: str = typer.Argument(...),
               root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Add a note to an open task (shown indented under it)."""
    g, i, t = _open_row(_ws(root, receipts), number)
    _run(ops.add_task_note, g["project"], str(i + 1), text)
    console.print(f"[green]note added[/] to {t['text']}  [dim]· {g['project'].title}[/]", highlight=False)


@tasks_app.command("photo")
def tasks_photo(number: int = typer.Argument(..., help="Task number from `proj tasks`"),
                file: Path = typer.Argument(..., help="Image file (copied into the project's Photos/ folder)"),
                note: Optional[str] = typer.Option(None, "--note", "-n", help="Caption for the photo"),
                root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Add a photo to an open task."""
    g, i, t = _open_row(_ws(root, receipts), number)
    ph = _run(ops.add_photo_file, g["project"], file, note, task=str(i + 1))
    console.print(f"[green]photo added[/] to {t['text']}: {ph['path']}  [dim]· {g['project'].title}[/]", highlight=False)


@tasks_app.command("link")
def tasks_link(number: int = typer.Argument(..., help="Task number from `proj tasks`"),
               target: str = typer.Argument(..., help="A URL, or a file under ~/Documents"),
               name: Optional[str] = typer.Option(None, "--name", help="Friendly name (default: the website or file name)"),
               root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Add a link (or a ~/Documents file) to an open task."""
    g, i, t = _open_row(_ws(root, receipts), number)
    f = _run(ops.add_task_file, g["project"], str(i + 1), target, name)
    console.print(f"[green]link added[/] to {t['text']}: {f['name']}  [dim]· {g['project'].title}[/]", highlight=False)


@tasks_app.command("remind")
def tasks_remind(number: int = typer.Argument(..., help="Task number from `proj tasks`"),
                 when: str = typer.Argument(..., metavar="WHEN", help='Date and time, "YYYY-MM-DD HH:MM" (a date alone means 09:00)'),
                 text: Optional[str] = typer.Option(None, "--text", "-t", help="Reminder text (default: the task's text)"),
                 root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Create an Apple Reminder for an open task (Reminders › Projects Tasks) and record it on the task."""
    g, i, t = _open_row(_ws(root, receipts), number)
    t = _run(reminders.schedule_task_reminder, g["project"], str(i + 1), when, text)
    console.print(f"[green]⏰ reminder set[/] for {reminders.reminder_label(t['reminder'])}: {text or t['text']}  "
                  f"[dim]· {g['project'].title}[/]", highlight=False)


@tasks_app.command("today")
def tasks_today(numbers: list[int] = typer.Argument(..., help="Task numbers from `proj tasks`"),
                root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Copy open tasks into Today by their numbers in `proj tasks` (linked: ticking either ticks both)."""
    ws = _ws(root, receipts)
    rows = {n: (g, i, t) for n, g, i, t in _open_numbered(ws)}
    bad = [n for n in numbers if n not in rows]
    if bad:
        _fail(f"no open task #{', #'.join(map(str, bad))} (see `proj tasks`)")
    picks = [(rows[n][0]["project"], rows[n][1]) for n in dict.fromkeys(numbers)]
    added = _run(ops.copy_many_to_today, ws, picks)
    for n in dict.fromkeys(numbers):
        console.print(f"[yellow]☀[/] {rows[n][2]['text']}  [dim]· {rows[n][0]['project'].title}[/]", highlight=False)
    skipped = len(picks) - added
    console.print(f"[green]copied {added} task{'s' if added != 1 else ''} to Today[/]"
                  + (f" [dim]({skipped} already there)[/]" if skipped else ""))


order_app = typer.Typer(invoke_without_command=True,
                        help="Order of areas, and of projects within each area, on the overview (1 = top).")
app.add_typer(order_app, name="order")


def _area(ws: Workspace, area: str) -> str:
    names = ops.overview_areas(ws)
    hits = [a for a in names if a.lower() == area.lower()] or [a for a in names if area.lower() in a.lower()]
    if len(hits) != 1:
        console.print(f"[red]{'No' if not hits else 'More than one'} area matches '{area}'[/] "
                      f"(areas: {', '.join(names)})", highlight=False)
        raise typer.Exit(1)
    return hits[0]


def _print_order(ws: Workspace, areas: list[str] | None = None) -> None:
    ov = ops.overview(ws)
    all_areas = ops.overview_areas(ws, ov)
    for n, a in enumerate(all_areas, 1):
        if areas is not None and a not in areas:
            continue
        ps = ops.area_projects(ws, a, ov)
        how = "manual order" if ov.has_order(a) else "status, then name"
        flag = "  [dim]▸ collapsed[/]" if ov.is_collapsed(a) else ""
        console.print(f"[bold]{n}. {a}[/] [dim]({how})[/]{flag}", highlight=False)
        for i, p in enumerate(ps, 1):
            closed = " [dim]closed[/]" if p.status == "closed" else ""
            console.print(f"   {i:3}. {p.title}{closed}", highlight=False)
        if not ps:
            console.print("[dim]        no projects[/]")


@order_app.callback()
def order_ls(ctx: typer.Context, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Show the areas in order, each with its projects (closed ones too; the Closed filter shows them)."""
    if ctx.invoked_subcommand:
        return
    _print_order(_ws(root, receipts))


@order_app.command("area")
def order_area(area: str, position: int, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Move an area to a position on the overview (1 = top)."""
    ws = _ws(root, receipts)
    _run(ops.move_area, ws, _area(ws, area), position)
    for i, a in enumerate(ops.overview_areas(ws), 1):
        console.print(f"{i:3}. {a}", highlight=False)


@order_app.command("mv")
def order_mv(project: str, position: int, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Move a project to a position within its area (1 = top). The area then keeps this order."""
    ws = _ws(root, receipts)
    p = _pick(ws, project)
    _run(ops.move_project, ws, p, position)
    _print_order(ws, [ops.project_area(ws, p)])


@order_app.command("reset")
def order_reset(area: Optional[str] = typer.Argument(None, help="Area whose projects to re-sort (default: all)"),
                areas: bool = typer.Option(False, "--areas", help="Sort the areas themselves A–Z again"),
                root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Go back to the default order: projects by status, then name; with --areas, areas A–Z."""
    ws = _ws(root, receipts)
    if areas:
        ops.reset_area_order(ws)
        console.print("areas: sorted A–Z")
        if not area:
            return
    a = _area(ws, area) if area else None
    ops.reset_order(ws, a)
    console.print(f"{a or 'all areas'}: projects sorted by status, then name", highlight=False)


def _collapse(areas: list[str], all_: bool, on: bool, root, receipts) -> None:
    ws = _ws(root, receipts)
    if not areas and not all_:
        console.print("[red]Name an area or use --all.[/]")
        raise typer.Exit(1)
    names = ops.overview_areas(ws) if all_ else [_area(ws, a) for a in areas]
    _run(ops.set_collapsed, ws, names, on)
    console.print(f"{'collapsed' if on else 'expanded'}: {', '.join(names)}", highlight=False)


@app.command()
def collapse(areas: list[str] = typer.Argument(None), all_: bool = typer.Option(False, "--all"),
             root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Collapse areas on the overview to just their name (web and iPhone)."""
    _collapse(areas or [], all_, True, root, receipts)


@app.command()
def expand(areas: list[str] = typer.Argument(None), all_: bool = typer.Option(False, "--all"),
           root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Expand collapsed areas again."""
    _collapse(areas or [], all_, False, root, receipts)


archive_app = typer.Typer(invoke_without_command=True,
                          help="Archived tasks from all projects (refer to one by its #number or text).")
app.add_typer(archive_app, name="archive")


def _since(value: Optional[str]) -> Optional[dt.date]:
    if not value:
        return None
    if re.fullmatch(r"\d+d", value):
        return dt.date.today() - dt.timedelta(days=int(value[:-1]))
    try:
        return dt.date.fromisoformat(value)
    except ValueError:
        raise typer.BadParameter("use YYYY-MM-DD or a number of days like 30d") from None


@archive_app.callback()
def archive_ls(ctx: typer.Context,
               project: Optional[str] = typer.Option(None, "--project", "-p", help="Only tasks from this project"),
               since: Optional[str] = typer.Option(None, "--since", "-s", help="Archived on/after YYYY-MM-DD, or e.g. 30d"),
               sort: str = typer.Option("newest", "--sort", help="newest | oldest | name | project"),
               root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """List archived tasks with their original project and archive date."""
    if ctx.invoked_subcommand:
        return
    ws = _ws(root, receipts)
    if project:
        names = ops.archive_projects(ws)
        hit = next((n for n in names if n.lower() == project.lower()), None)
        if hit is None:
            hits = [n for n in names if project.lower() in n.lower()]
            if len(hits) != 1:
                _fail(f"no archived tasks from '{project}'" if not hits else f"'{project}' matches {', '.join(hits)}")
            hit = hits[0]
        project = hit
    items = _run(ops.archived_tasks, ws, project, _since(since), sort)
    for i, t in items:
        console.print(f"[dim]#{i + 1:<3}[/] {'[green]✔[/]' if t['done'] else '☐'} {t['text']}  "
                      f"[cyan]{t['from'] or '?'}[/] [dim]· {t['archived'] or '?'}[/]", highlight=False)
        _print_task_details(t)
    if not items:
        console.print("[dim]No archived tasks" + (" match." if project or since else ". Archive one with `proj task archive <project> <task>`.") + "[/]")


@archive_app.command("restore")
def archive_restore(task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Move an archived task back to its project."""
    t, p = _run(ops.restore_task, _ws(root, receipts), task)
    console.print(f"[green]restored to {p.title}:[/] {t['text']}", highlight=False)


@archive_app.command("rm")
def archive_rm(task: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Delete an archived task for good."""
    a = _ws(root, receipts).archive()
    if a is None:
        _fail("the Archive is empty")
    t = _run(ops.remove_task, a, task)
    console.print(f"deleted from the Archive: {t['text']}", highlight=False)


photo_app = typer.Typer(no_args_is_help=True,
                        help="Photos of a project or of a task, each with a note (files in the project's Photos/ folder).")
app.add_typer(photo_app, name="photo")
TaskOpt = typer.Option(None, "--task", "-t", help="The task (number or text) instead of the project")


@photo_app.command("add")
def photo_add(project: str, image: Path, note: str = typer.Option("", "--note", "-n"), task: Optional[str] = TaskOpt,
              root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Copy an image into the project's Photos/ folder and add it (with a note) to the project or a task."""
    p = _pick(_ws(root, receipts), project)
    ph = _run(ops.add_photo_file, p, image, note, task)
    console.print(f"[green]added[/] {ph['path']}" + (f" — {ph['note']}" if ph["note"] else ""), highlight=False)


@photo_app.command("ls")
def photo_ls(project: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """List the project's photos and its tasks' photos."""
    p = _pick(_ws(root, receipts), project)
    for i, ph in enumerate(p.photos, 1):
        console.print(f"{i:3}. {ph['note'] or '[dim](no note)[/]'}  [dim]{ph['path']}[/]", highlight=False)
    for n, t in enumerate(p.tasks, 1):
        if t["photos"]:
            console.print(f"[bold]task {n}: {t['text']}[/]", highlight=False)
            for i, ph in enumerate(t["photos"], 1):
                console.print(f"  {i:3}. {ph['note'] or '[dim](no note)[/]'}  [dim]{ph['path']}[/]", highlight=False)
    if not p.photos and not any(t["photos"] for t in p.tasks):
        console.print("[dim]No photos yet.[/]")


@photo_app.command("note")
def photo_note(project: str, photo: str, note: str, task: Optional[str] = TaskOpt,
               root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Change a photo's note (photo by number or note text)."""
    p = _pick(_ws(root, receipts), project)
    ph = _run(ops.edit_photo_note, p, photo, note, task)
    console.print(f"{ph['path']}: {ph['note']}", highlight=False)


@photo_app.command("rm")
def photo_rm(project: str, photo: str, task: Optional[str] = TaskOpt,
             root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Remove a photo and delete its file."""
    p = _pick(_ws(root, receipts), project)
    ph = _run(ops.remove_photo, p, photo, task)
    console.print(f"removed {ph['path']}", highlight=False)


@photo_app.command("open")
def photo_open(project: str, photo: str = typer.Argument("1"), task: Optional[str] = TaskOpt,
               root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Open a photo in Preview."""
    p = _pick(_ws(root, receipts), project)
    photos = p.photos if task is None else p.tasks[_run(ops._task_index, p, task)]["photos"]
    f = ops.photo_path(p, photos[_run(ops._photo_index, photos, photo)]["path"])
    if not f.exists():
        console.print(f"[red]file not found: {f}[/]")
        raise typer.Exit(1)
    subprocess.run(["open", str(f)])


file_app = typer.Typer(no_args_is_help=True,
                       help="Manage Project Files links (files under ~/Documents or URLs; refer by number or name).")
app.add_typer(file_app, name="file")


@file_app.command("ls")
def file_ls(project: str, paths: bool = typer.Option(False, "--paths", "-p", help="Show the actual path/URL"),
            root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    p = _pick(_ws(root, receipts), project)
    for i, f in enumerate(p.files, 1):
        icon = "🔗" if f["kind"] == "url" else "📄"
        full = f["target"] if f["kind"] == "url" else str(ops.resolve_file(f["target"]))
        extra = f"  [dim]{full}[/]" if paths else ""
        console.print(f"{i:3}. {icon} {f['name']}{extra}", highlight=False)
    if not p.files:
        console.print("[dim]No project files.[/]")


@file_app.command("add")
def file_add(project: str, target: str = typer.Argument(..., help="Documents/… path, ~/Documents/… path, or URL"),
             name: Optional[str] = typer.Option(None, "--name", "-n", help="Friendly name (default: file name / site)"),
             root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Add a link to a file under ~/Documents or to a URL."""
    p = _pick(_ws(root, receipts), project)
    f = _run(ops.add_file, p, target, name)
    if f["kind"] == "file" and not ops.resolve_file(f["target"]).exists():
        console.print(f"[yellow]note: {f['target']} does not exist (yet)[/]")
    console.print(f"[green]added[/] {f['name']}  [dim]{f['target']}[/]", highlight=False)


@file_app.command("edit")
def file_edit(project: str, entry: str,
              name: Optional[str] = typer.Option(None, "--name", "-n"),
              target: Optional[str] = typer.Option(None, "--target", "-t", help="New path or URL"),
              root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    f = _run(ops.edit_file, _pick(_ws(root, receipts), project), entry, name, target)
    console.print(f"edited: {f['name']}  [dim]{f['target']}[/]", highlight=False)


@file_app.command("rm")
def file_rm(project: str, entry: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    f = _run(ops.remove_file, _pick(_ws(root, receipts), project), entry)
    console.print(f"removed: {f['name']}", highlight=False)


@file_app.command("open")
def file_open(project: str, entry: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Open the file (default app) or URL (browser)."""
    p = _pick(_ws(root, receipts), project)
    _run(ops.open_file_entry, p.files[_run(ops._file_index, p, entry)])


link_app = typer.Typer(no_args_is_help=True, help="Manage links.")
app.add_typer(link_app, name="link")


@link_app.command("add")
def link_add(project: str, url: str, title: Optional[str] = typer.Option(None, "--title", "-t"),
             root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    p = _pick(_ws(root, receipts), project)
    _run(ops.add_link, p, url, title)
    console.print(f"[green]linked[/] {url}")


receipt_app = typer.Typer(no_args_is_help=True, help="Manage receipts.")
app.add_typer(receipt_app, name="receipt")


@receipt_app.command("add")
def receipt_add(project: str, file: Path,
                amount: Optional[float] = typer.Option(None, "--amount", "-$"),
                vendor: Optional[str] = typer.Option(None, "--vendor", "-v"),
                date: Optional[str] = typer.Option(None, "--date", "-d", help="YYYY-MM-DD (default today)"),
                root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Attach a receipt by reference: the file stays where it is (it must be under ~/Documents) and is tagged 'receipt'. Nothing is copied."""
    ws = _ws(root, receipts)
    try:
        d = dt.date.fromisoformat(date) if date else None
    except ValueError:
        console.print(f"[red]bad date: {date}[/]")
        raise typer.Exit(1)
    e = _run(ops.add_receipt, ws, _pick(ws, project), file, amount, vendor, d)
    console.print(f"[green]attached[/] {e['path']}")


idea_app = typer.Typer(no_args_is_help=True, help="Idea backlog.")
app.add_typer(idea_app, name="idea")


@idea_app.command("ls")
def idea_ls(root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    for i, t in enumerate(ops.ideas(_ws(root, receipts)), 1):
        console.print(f"{i:3}. {t}")


@idea_app.command("add")
def idea_add(text: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    ops.add_idea(_ws(root, receipts), text)
    console.print("[green]added[/]")


@idea_app.command("rm")
def idea_rm(idea: str, root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    console.print(f"removed: {_run(ops.remove_idea, _ws(root, receipts), idea)}")


@idea_app.command("promote")
def idea_promote(idea: str, area: str = typer.Option(..., "--area", "-a"),
                 title: Optional[str] = typer.Option(None, "--title", "-t"),
                 root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Turn an idea into a project."""
    p = _run(ops.promote_idea, _ws(root, receipts), idea, area, title)
    console.print(f"[green]created[/] {p.dir}")


@app.command()
def serve(port: int = typer.Option(8765, "--port", "-p"),
          open_browser: bool = typer.Option(True, "--open/--no-open", help="Open the browser"),
          root: Optional[Path] = RootOpt, receipts: Optional[Path] = ReceiptsOpt):
    """Run the local web UI (bound to 127.0.0.1 only)."""
    import threading
    import webbrowser

    import uvicorn

    from .web.app import create_app

    url = f"http://127.0.0.1:{port}/"
    console.print(f"Projects UI at [bold]{url}[/]  (Ctrl-C to stop)")
    if open_browser:
        threading.Timer(1.0, webbrowser.open, args=(url,)).start()
    uvicorn.run(create_app(_ws(root, receipts)), host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    app()
