# projkit — `proj`

CLI and local web UI for the project folders in `~/Documents/Projects`.
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
proj link add web https://… -t "Docs"
proj receipt add roof ~/Downloads/inv.pdf -$ 412.50 -v Lowes --desc "Shingles"
proj status photo on-hold
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
project pages (edit Description/Project Files, goals, notes, links, receipt upload, status/close/rename,
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
