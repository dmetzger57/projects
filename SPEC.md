# Project Folder Format — v1

This is the contract shared by the `proj` CLI, the web UI and the SwiftUI iPhone app (`ios/`).
The files are the source of truth; any index/database is a rebuildable cache.

## Layout

```
$PROJ_ROOT (default ~/Documents/Projects)
├── 0 - Idea Backlog.md          backlog (ideas.md format, see below)
├── 1 - Template/                template copied by `proj new`
├── 2 - Closed/<Project>/        closed projects (flat; area kept in front matter)
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
status: active                      # idea | active | on-hold | closed
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

## Project Files
Free text describing contents of Documents/.

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
- Unknown front-matter keys must be preserved (forward compatibility).

Optional keys written by tools:
- `migrated_from: Readme.pages` — set by `proj migrate`; the original is kept as `Readme.legacy.pages`.

## Idea backlog (`0 - Idea Backlog.md`)

A heading/intro followed by one `- ` bullet per idea. Writers preserve everything before the first bullet.

```markdown
# Idea Backlog

- Backyard Sequoia tree
```

## Receipts

Files live in `$PROJ_RECEIPTS/<year>/YYYY-MM-DD <description>.<ext>` and carry the Finder tag `receipt`
(the iPhone app cannot set tags; `proj lint` reports untagged receipts as L013 and `--fix` adds the tag).
Projects reference them by path relative to `$PROJ_RECEIPTS`; files are never duplicated into projects.

## Naming

Project folder names are unique across all areas (case-insensitive), because `2 - Closed` is flat.

## Machine schema

`schema/project.schema.json` (JSON Schema 2020-12) validates the front matter.
