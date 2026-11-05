# Project Folder Format — v1

This is the contract shared by the `proj` CLI, the web UI and the SwiftUI iPhone app (`ios/`).
The files are the source of truth; any index/database is a rebuildable cache.

## Layout

```
$PROJ_ROOT (default ~/Documents/Projects)
├── 0 - Idea Backlog.md          backlog (ideas.md format, see below)
├── 1 - Template/                template copied by `proj new`
├── 2 - Closed/<Project>/        closed projects (flat; area kept in front matter)
├── 3 - Receipts/                optional receipts root inside the workspace (iPhone setup for
│                                people without ~/Documents/Receipts; same <year>/ layout)
└── <Area>/<Project>/
    ├── README.md                required
    ├── Documents/               required
    └── Receipts/                required (may stay empty; receipts are referenced, see below)
```

- Top-level folders whose names match `^\d+ - ` are reserved; all other top-level folders are **areas**.
- Hidden files (`.DS_Store`, …) are ignored.
- **No symlinks or Finder aliases.** `~/Documents` is iCloud-synced and symlinks do not sync reliably.

## README.md

YAML front matter, then a Markdown body.

```yaml
---
format: 1
title: Digital Photo Archive        # display name; should equal the folder name
area: Digital Infrastructure        # must equal parent folder unless closed
status: active                      # idea | backlog | active | blocked | on-hold | closed
created: 2026-11-02
closed: null                        # date when status = closed
tags: [photos]
goals:
  - text: Define updated storage structure
    done: false
  - text: Define keyword scheme
    done: true
    done_on: 2026-11-05
links:
  - title: Web-Check
    url: https://github.com/Lissy93/web-check
receipts:
  - path: 2026/2026-11-04 B&H scanner.pdf   # relative to $PROJ_RECEIPTS (default ~/Documents/Receipts)
    amount: 412.50
    vendor: B&H
    date: 2026-11-04
---

## Description
Free text.

## Tasks
- [ ] Order scanner
  - Ask about the 3-year warranty
  - [Quote](<Documents/Quotes/Epson FF-680W.pdf>)
  - [Product page](https://epson.com/ff-680w)
- [x] Pick storage location

## Project Files
- [Scanner manual](<Documents/Manuals/Epson FF-680W.pdf>)
- [Planning doc](https://docs.google.com/document/d/…/edit)

## Notes
### 2026-11-02
- Initial template format
```

Rules:
- Front-matter key order must be preserved by writers. Keys a writer does not change must be
  preserved; the Python tool also keeps comments, and the iPhone app re-emits untouched keys
  byte-for-byte (comments on changed keys may be dropped).
- The iPhone app only edits keys it fully understands (scalars, flow lists, block lists of
  scalars or flat mappings); keys using other YAML (block scalars, anchors, nesting) are left as is.
- Dates are ISO `YYYY-MM-DD`.
- Notes are `### YYYY-MM-DD` headings under `## Notes`, newest last; writers append to today's heading or create it.
- Tasks are GitHub-style task-list lines (`- [ ] text`, `- [x] text`) in an optional `## Tasks` section; any other
  lines in that section (intro text, indented details) are kept. Tasks are numbered by order of their lines.
  Writers add new tasks after the last task line, creating the section just before `## Notes` (or at the end)
  when missing; editing or ticking changes only that line. Indented, non-blank lines directly under a task
  are its details: moving or deleting a task moves or deletes them with it. List order is the file order,
  so reordering moves lines. A task's attachments are detail lines that are indented Project Files links
  (`  - [Friendly name](<Documents/…>)` or `  - [Name](https://…)`, same target rules as Project Files below);
  writers indent them two spaces and add new ones after the task's last attachment (else at the end of its
  detail lines), and a new task goes after the last task's detail lines. Files are referenced by path, never
  copied; `proj lint` reports attachments pointing at missing files as L014. Every other detail line is a
  task note, shown indented below the task: its text is the line without indentation and without a leading
  `- ` or `* `. Writers store a note as one line `  - text` (newlines folded to spaces), add new ones after
  the task's last note (else directly under the task line), and refuse a note that would read as an attachment. Goals (front matter) are longer-term outcomes;
  tasks are the to-do checklist.
- **Today list:** `0 - Today/README.md` at the projects root is a project outside the areas (front matter
  `title: Today`, `area: Today`), created on first use. Its `## Tasks` are the tasks to do today. A task copied
  in from a project gets a link id, written at the end of both task lines as `<!-- task:k3x9q2ab -->` (8 chars
  of `a-z2-9`, hidden when rendered); the visible text is the line without it, and editing a task keeps it.
  Ticking or unticking any task with an id sets every task with that id (in Today and all projects, closed
  ones included) the same way. A task is copied at most once; removing or clearing it from Today leaves the
  original alone. Tasks added directly to Today have no id.
- Unknown front-matter keys must be preserved (forward compatibility).

- Project Files entries are Markdown links on their own line: `- [Friendly name](<target>)`. The target is
  either a URL (`scheme://…`) or a file path relative to the home folder that starts with `Documents/`
  (so it resolves to ~/Documents on the Mac and iCloud Drive › Documents on the iPhone). File targets are
  always written in angle brackets; URLs only when they contain spaces or parentheses. Names never contain
  `[` or `]` (writers replace them with parentheses); an empty name defaults to the file name without its
  extension, or the URL's host without `www.`. Targets must not contain `<`, `>`, `..` segments or line
  breaks. Other lines in the section are free text and are kept. `proj lint` reports links to missing
  files as L014.

Optional keys written by tools:
- `migrated_from: Readme.pages` — set by `proj migrate`; the original is kept as `Readme.legacy.pages`.

## Idea backlog (`0 - Idea Backlog.md`)

A heading/intro followed by one `- ` bullet per idea. Writers preserve everything before the first bullet.

```markdown
# Idea Backlog

- Backyard Sequoia tree
```

## Receipts

The receipt file is the single source of truth. Adding a receipt records where the file already is;
it is **never copied or moved**. Each entry's `path` is either

- relative to `$PROJ_RECEIPTS` (default `~/Documents/Receipts`) when the file lives there, e.g. `2026/2026-10-09 Shingles.pdf`, or
- `Documents/…` (relative to the home folder, the same form as Project Files) for a file anywhere else under `~/Documents`.

Files outside `~/Documents` are refused, since the iPhone app could not reach them. The only time a new
file is written is a document scanned on the iPhone (it has no other original), which is saved as
`$PROJ_RECEIPTS/<year>/YYYY-MM-DD <description>.pdf`. Receipt files carry the Finder tag `receipt`
(the iPhone app cannot set tags; `proj lint` reports untagged receipts as L013 and `--fix` adds the tag).

## Naming

Project folder names are unique across all areas (case-insensitive), because `2 - Closed` is flat.

## Machine schema

`schema/project.schema.json` (JSON Schema 2020-12) validates the front matter.
