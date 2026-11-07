# Project Instructions

## Feature Scope
- All new feature requests must include solutions for:
  - Web UI
  - macOS (OSX)
  - iPhone (iOS)
  - iPad (iPadOS)
  - CLI
- Before building a "new" feature, grep for it first: several requests have turned out to exist
  already (Collapse/Expand All, Reopen). Then report where it lives, or make it easier to find.

## What this is
`proj`: a project tracker over plain folders in `~/Documents/Projects` (iCloud Drive). Each project is a
folder with a `README.md` (YAML front matter + Markdown body). **The files are the source of truth**;
the format is defined in `SPEC.md`. There is no database and no server-side state.

Two implementations of the same core, which must stay byte-identical in what they write:

| Layer | Python (`src/projkit/`) | Swift (`ios/ProjKit/Sources/ProjKitCore/`) |
|---|---|---|
| Model / parsing | `project.py` (`STATUSES`, `status_label`, task regexes) | `Project.swift` (`projectStatuses`, `statusLabel`, `ReadmeBody`) |
| Operations | `ops.py` (`body_*` pure string functions + ops that save) | `Ops.swift` (`Ops.*`; `editBody`, `setKeys`, `fresh`) |
| Workspace / dirs | `workspace.py` | `Workspace.swift` |
| Overview layout | `ops.py` (`STATUS_ORDER`, overview fns) | `Overview.swift` (`projectStatusOrder`) |
| Front matter YAML | ruamel round-trip | `FrontMatter.swift` (hand-written, round-trip safe) |

Front ends:
- **CLI**: `src/projkit/cli.py` (typer + rich). Entry point `proj`.
- **Web UI**: `src/projkit/web/app.py` (FastAPI + Jinja + htmx), templates in `web/templates/`, CSS in
  `web/static/style.css` (color tokens on `:root`, dark mode via `prefers-color-scheme`). Mutations
  return a partial, or `204` with `HX-Refresh` (`_refresh()`) / `HX-Redirect` (`redirect()`).
  Jinja has no list comprehensions: loop and call helpers (`status_label`) instead.
- **Mac / iPhone / iPad**: one multiplatform SwiftUI target in `ios/App/` (not Catalyst). Key views:
  `ProjectsView.swift` (list, area headers, row context menus, `StatusBadge`, `ReopenMenu`),
  `Layout.swift` (iPad/Mac overview tiles), `ProjectDetailView.swift` (project page, Actions menu),
  `Sheets.swift`, `TodayView.swift`, `ArchiveView.swift`. `AppModel.perform { ws in … }` runs an `Ops`
  call off the main thread, then reloads. Platform differences use `#if os(macOS)`.

## Rules that span both implementations
- Any change to file format or op behavior goes in **both** `ops.py` and `Ops.swift`, with the same test
  steps in `tests/*.py` and `ios/ProjKit/Sources/Checks/main.swift` (comments name the mirror, e.g.
  "same steps as tests/test_today.py"). Status lists/order/labels exist in both too.
- Statuses: `idea | backlog | active | blocked | on-hold | completed-on-hold | closed` (+ `legacy` for
  folders with no README.md). Stored lowercase; displayed title-case via `status_label`/`statusLabel`.
  `closed` is never set by `set_status`: use close/reopen (moves the folder to/from `2 - Closed`).
- Tasks (`## Tasks`, `- [ ]`/`- [x]`): done tasks settle at the bottom; new/restored/moved-in tasks go
  above the done ones. Ticking the last open task sets `completed-on-hold` (not for closed, Today,
  Archive). A task copied to Today carries `<!-- task:id -->`; ticking either copy ticks both.
- Special folders at the root: `0 - Today`, `0 - Archive`, `0 - Overview.md` (area order, collapsed
  areas, manual project order), `0 - Idea Backlog.md`, `1 - Template`, `2 - Closed`, `3 - Receipts`.
  Areas are the other top-level folders.

## Commands
- `make check`: everything — `make test` (pytest), `make checks` (Swift core checks via
  `swift run Checks`, no Xcode), `make crosscheck` (Swift mutates a **copy** of the real
  `~/Documents/Projects`, then Python verifies it). The crosscheck runs on real data, so never assume
  Today/areas are empty: look tasks up by text, not position.
- Compile the apps without installing:
  `xcodebuild -project ios/Proj.xcodeproj -scheme Proj -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
  (and `-destination 'generic/platform=iOS Simulator'`). Use a scratch `-derivedDataPath`.
- `make install-mac` installs the Mac app in /Applications and opens it (prints a harmless
  "failed with exit code 0" line). `make install` = Mac + connected iPhone/iPad.
- The web UI runs under launchd: after web changes, `make restart-web`.
- `make version V=x.y.z` bumps the version (VERSION is copied into pyproject, `__init__`, Xcode; a test checks).
- Python venv: `.venv/bin/pytest`, `.venv/bin/python`.

## Working conventions
- Commits go directly on `main` and are pushed to `origin` (github.com:dmetzger57/projects) when asked.
- Commit messages: short imperative subject, bullet body explaining what changed per front end.
- Docs to update with user-visible changes: `README.md` (CLI usage), `SPEC.md` (file format/rules),
  `ios/README.md` (app features), `schema/project.schema.json` (front matter).
- Screenshots the user shares are `.heic` with a narrow no-break space before "PM" in the name: match
  with a glob and convert with `sips -s format png` before reading.
