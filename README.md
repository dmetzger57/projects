# projkit — `proj`

CLI, local web UI, and iPhone/iPad/Mac app ([ios/](ios/README.md)) for the project folders in `~/Documents/Projects`.
The file format is defined in [SPEC.md](SPEC.md); the files are the source of truth.

## Setup

```sh
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
ln -s "$PWD/.venv/bin/proj" ~/bin/proj   # or add .venv/bin to PATH
```

Common tasks are in the [Makefile](Makefile) (`make` lists them): `make check` (Python tests, Swift checks,
cross-check), `make restart-web`, `make install` (Mac, iPhone and iPad; `make install-mac` for just the Mac), `make sim TAB=projects` / `make screenshot`
(simulator on a copy of your projects), `make release`.

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
proj task today photo <task>            # copy a task into the Today list (web: ☀; iPhone: swipe right)
proj today                              # Today's tasks, each with the project it came from
proj today add "Call the bank"          # …or add one directly
proj today done|undo|rm <task>          # ticking a copy ticks its original too (and vice versa)
proj today clear                        # remove done tasks from Today; originals stay ticked
proj task archive photo <task>          # move a task (notes, attachments) to the Archive (web: 🗄; iPhone: swipe left)
proj task move-to photo <task> roof     # move a task (notes, attachments, photos) to the end of another project (web: ↪; iPhone: swipe right › Move, or long-press › Move to Project…)
proj task remind photo <task> "2026-11-10 09:00"   # Apple Reminder in Reminders › Projects Tasks; --text "…" to change
                                        # its text (default: the task's), --clear to forget it (web: ⏰; iPhone: swipe right › Remind,
                                        # or long-press › Add Reminder…). The task shows ⏰ with the time. macOS only for CLI/web.
proj tasks                              # All Open Tasks: every open task of every project that isn't closed, by project
proj tasks -s quote --area House        # …filtered; numbers stay the same as the full list
proj tasks today 2 5 7                  # copy those to Today (linked). Web: Open Tasks page, check tasks › ☀ Copy to Today;
                                        # iPhone/iPad/Mac: Open Tasks tab, tap tasks › Copy to Today
proj tasks show 5                       # open one: its project, notes, attachments, reminder (web/app: ↗ opens the project at it)
proj tasks edit 5 "new text"            # edit one (web/app: ✎; app: also swipe left or long-press › Edit…)
proj tasks note 5 "Ask about cedar"     # add a note    (web: 📝; app: ⋯ › Add Note…)
proj tasks photo 5 ~/Desktop/a.jpg -n "Sample"   # add a photo (web: 📷; app: ⋯ › Take/Choose Photo…)
proj tasks link 5 https://example.com --name "Supplier"   # add a link (web: 🔗; app: ⋯ › Add Link…)
proj tasks link-rm 5 Supplier           # remove a link: # from `proj tasks show`, or part of its name (web: × by it; app: ⋯ › Remove Link)
proj tasks photo-rm 5 1                 # delete a photo and its file (web: × under it; app: ⋯ › Delete Photo)
proj tasks remind 5 "2026-11-20 10:00"  # Apple Reminder (web: ⏰; app: ⋯ › Add Reminder…)
proj task ls photo --archived           # …and list the project's archived tasks below its own
proj archive                            # all archived tasks with their project and date (web/iPhone: Archive)
proj archive -p photo --since 30d --sort name   # filter by project / date (YYYY-MM-DD or Nd); sort newest|oldest|name|project
proj archive restore|rm <#n>            # move one back into its project, or delete it for good
proj photo add roof ~/Desktop/leak.jpg -n "Leak over the garage"   # copied into Roof/Photos/; -t <task> for a task
proj photo ls|note|rm|open roof <photo> [-t <task>]                 # web: Photos section, 📷 on a task
proj link add web https://… -t "Docs"
proj file add photo "Documents/Manuals/scanner.pdf" -n "Scanner manual"   # Project Files link
proj file add photo https://docs.google.com/… -n "Plan"                    # …or a URL
proj file ls|edit|rm|open photo <entry>   # ls --paths shows targets
proj receipt add roof ~/Documents/Receipts/2026/inv.pdf -$ 412.50 -v Lowes   # records the path; no copy
proj receipt import roof ~/Desktop/IMG_0042.jpg -$ 19.99 -v "Home Depot"    # a photo: copied to Receipts/<year>/<date> Home Depot.jpg
proj receipt import roof --from-photos -v Lowes                             # …the photo selected in the Photos app
proj status photo blocked                # idea | backlog | active | blocked | on-hold | completed-on-hold
                                         # (set automatically when the last open task is ticked)
proj order                               # areas in order, each with its projects (1 = top)
proj order area House 1                  # move an area (web: drag the area's ⋮⋮ or ↑/↓; iPhone: area ⋯ › Move / Reorder Areas)
proj order mv photo 1                    # move a project within its area (web: drag the tile's ⋮⋮; iPhone: drag or long-press)
proj order reset [AREA] [--areas]        # projects back to status, then name; --areas: areas A–Z
proj collapse House [Garden …] | --all   # area shows just its name (web: click the area name; iPhone: tap it)
proj expand House | --all
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

## Versions

`VERSION` holds the version (`1.2.3`), shown by `proj --version`, in the web UI footer, and in the iPhone/iPad
app under Settings › About (with the build number: the commit count for `make install`, date-based for TestFlight).
`scripts/version.py` copies it into `pyproject.toml`, `src/projkit/__init__.py` and the Xcode project, and a test
fails if they ever disagree.

```sh
make version              # current version, git describe, build number
make version V=1.2.0      # on an up-to-date, clean main: bump, commit "Version 1.2.0", tag v1.2.0, push both
```

## Web UI

`proj serve` opens http://127.0.0.1:8765/ — overview by area (filters, search, goal progress, spend; click an
area's name to collapse it to just the name, drag ⋮⋮ to reorder areas or the projects in an area),
project pages (edit Description/Project Files, goals, notes, links, receipts by path or from Photos, status/close/rename,
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
