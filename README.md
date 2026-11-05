# projkit — `proj`

CLI, local web UI and iPhone app ([ios/](ios/README.md)) for the project folders in `~/Documents/Projects`.
The file format is defined in [SPEC.md](SPEC.md); the files are the source of truth.

## Setup

```sh
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
ln -s "$PWD/.venv/bin/proj" ~/bin/proj   # or add .venv/bin to PATH
```

Environment: `PROJ_ROOT` (default `~/Documents/Projects`), `PROJ_RECEIPTS` (default `~/Documents/Receipts`).

## Commands

Projects are referenced by (partial/fuzzy) name; goals and ideas by number or text.

```sh
proj ls [-a AREA] [-s STATUS] [--closed]
proj show photo
proj new "Roof Repair" -a House
proj note photo "Bought a scanner"
proj goal add|done|undo|rm photo <goal>
proj task ls photo                      # Tasks checklist (## Tasks in README.md)
proj task add|done|undo|rm photo <task>
proj task edit photo <task> "new text"
proj task mv photo <task> 1             # reorder (1 = top); web: drag ⋮⋮ or ↑/↓; iPhone: drag or long-press
proj task attach photo <task> ~/Documents/Quotes/epson.pdf   # or a URL; --name "Quote"; linked, never copied
proj task detach|open photo <task> <attachment>              # web: 📎 on a task; iPhone: long-press › Attach
proj task note photo <task> "Ask about the warranty"         # notes shown indented under the task
proj task note-edit|note-rm photo <task> <note> ["new text"] # web: 📝, ✎, ×; iPhone: long-press › Add Note, tap a note to edit
proj link add web https://… -t "Docs"
proj file add photo "Documents/Manuals/scanner.pdf" -n "Scanner manual"   # Project Files link
proj file add photo https://docs.google.com/… -n "Plan"                    # …or a URL
proj file ls|edit|rm|open photo <entry>   # ls --paths shows targets
proj receipt add roof ~/Documents/Receipts/2026/inv.pdf -$ 412.50 -v Lowes   # records the path; no copy
proj status photo blocked                # idea | backlog | active | blocked | on-hold
proj rename web "Web-Check Service"
proj close roof            # → 2 - Closed, area kept
proj reopen roof [-a AREA]
proj idea ls|add|rm|promote <idea> -a House
proj open photo            # Finder
proj edit photo            # $EDITOR
proj lint [--fix]
proj migrate [--dry-run]   # one-time Readme.pages → README.md (drives Pages)
proj serve [-p 8765] [--no-open]   # web UI
```

## Web UI

`proj serve` opens http://127.0.0.1:8765/ — overview by area (filters, search, goal progress, spend),
project pages (edit Description/Project Files, goals, notes, links, receipts by path, status/close/rename,
reveal in Finder), idea backlog with "Make project", and a Health page with one-click lint fixes.

- Reads the files on every request and polls for changes, so CLI/Finder/iCloud edits appear live.
- Bound to 127.0.0.1; rejects other Host headers and non-htmx POSTs (DNS-rebinding/CSRF guard).
- No CDN: htmx 2.0.4 is vendored in `src/projkit/web/static/`.

## Layout

- `src/projkit/project.py` — README model (round-trip YAML front matter, sections, notes)
- `src/projkit/workspace.py` — discovery of areas/projects, lookup
- `src/projkit/ops.py` — all mutations (shared by CLI and UI)
- `src/projkit/lint.py` — structural checks + safe fixes
- `src/projkit/migrate.py` — Pages export via AppleScript (Word for structure, PDF for URLs)
- `src/projkit/cli.py` — Typer CLI
- `src/projkit/web/` — FastAPI + htmx UI (`app.py`, `templates/`, `static/`)
