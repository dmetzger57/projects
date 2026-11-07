#!/bin/sh
# Swift ↔ Python compatibility check: the Swift core edits a COPY of the projects
# tree, then the Python tool must load the result, read every value back, and lint it
# without errors. Never touches the real ~/Documents/Projects.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
SRC=${PROJ_ROOT:-$HOME/Documents/Projects}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Receipts"
ditto "$SRC" "$TMP/Projects"

(cd "$HERE/ProjKit" && swift run -q Checks --mutate "$TMP/Projects" "$TMP/Receipts")

"$REPO/.venv/bin/python" - "$TMP" <<'EOF'
import datetime, sys
from pathlib import Path
from projkit import ops
from projkit.lint import lint_workspace
from projkit.project import Project
from projkit.workspace import Workspace
T = Path(sys.argv[1]); ws = Workspace(T / "Projects", T / "Receipts")
p = ws.find("Photo Archive")[0]
assert p.title == "Photo Archive" and p.status == "blocked"
ov = ops.overview(ws)                                    # overview written by Swift, renamed with the project
assert ops.area_projects(ws, ops.project_area(ws, p), ov)[0].folder_name == "Photo Archive", ov
assert ov.is_collapsed(ops.project_area(ws, p)) and ops.overview_areas(ws, ov)[0] == ops.project_area(ws, p), ov
assert p.goals[0]["done"] is True and str(p.goals[0]["done_on"]) == datetime.date.today().isoformat()
assert p.goals[-1]["text"] == "Buy a scanner: Epson FF-680W"
assert p.links[-1] == {"title": 'Example: "quoted"', "url": "https://example.com/a?b=c#d"}
assert p.receipts[0]["amount"] == 649.99 and p.total_cost == 649.99
assert p.section("Description") == "Consolidate **all** photos.\n\n- prints\n- slides"
assert p.notes[-1].text.endswith("- Edited on iPhone\n  second line")
assert [(t["text"], t["done"]) for t in p.tasks] == [("Move me to the top", False), ("Order Epson FF-680W", False),
                                                    ("Pick storage", True)], p.tasks
assert [(f["name"], f["target"], f["kind"]) for f in p.tasks[1]["files"]] == [
    ("Epson quote", "Documents/Quotes/Epson quote.pdf", "file"),
    ("Product page", "https://epson.com/ff-680w", "url")], p.tasks[1]
assert ops.add_task_file(p, "Order", "https://b-h.example/epson")["name"] == "b-h.example"
assert p.tasks[1]["notes"] == ["Ask about the 3-year warranty", "Check B&H and Adorama prices"], p.tasks[1]
assert [ph["note"] for ph in p.photos] == ["Shelf (old) scanner"], p.photos     # photos written by Swift
assert [ph["note"] for ph in p.tasks[1]["photos"]] == ["Quote"], p.tasks[1]
assert all((p.dir / ph["path"]).is_file() for ph in p.photos + p.tasks[1]["photos"])
MINE = ("Move me to the top", "Pick storage", "Call the bank")
def mine():                                              # Swift's tasks in Today, wherever they settled
    return {t["text"]: (n, t) for n, t in enumerate(ws.today().tasks, 1) if t["text"] in MINE}
def task(q, text):                                       # a project task by its text
    return next(t for t in Project.load(q.dir).tasks if t["text"] == text)
m = mine()                                               # Today written by Swift (among any real tasks)
assert {x: t["done"] for x, (_, t) in m.items()} == {MINE[0]: False, MINE[1]: True, MINE[2]: False}, ws.today().tasks
assert m[MINE[0]][1]["id"] == p.tasks[0]["id"] and m[MINE[1]][1]["id"] == p.tasks[2]["id"] and m[MINE[2]][1]["id"] is None
ops.set_task(ws.today(), str(m[MINE[0]][0]), True, ws)   # Python ticks Swift's copy -> original ticks
assert task(p, MINE[0])["done"] is True
assert Project.load(p.dir).tasks[-1]["text"] == MINE[0]  # ... and settles at the bottom
ops.set_task(Project.load(p.dir), "Move me", False, ws)
assert mine()[MINE[0]][1]["done"] is False
p = Project.load(p.dir)
assert task(p, MINE[0])["notes"] == [], p.tasks
assert ops.edit_task_note(p, "Order", "warranty", "Ask about the warranty") == "Ask about the warranty"
assert task(p, "Order Epson FF-680W")["notes"][0] == "Ask about the warranty"
assert [(f["name"], f["target"], f["kind"]) for f in p.files] == [
    ("Scanner manual", "Documents/Manuals/Epson FF-680W.pdf", "file"),
    ("Plan", "https://docs.google.com/document/d/abc/edit?tab=t.0", "url")], p.files
ops.edit_file(p, "Plan", name="Planning doc")
assert Project.load(p.dir).files[1]["name"] == "Planning doc"
ops.set_task(p, "Order", True)
ops.move_task(p, "Pick", 1)
assert [t["text"] for t in Project.load(p.dir).tasks] == ["Pick storage", "Move me to the top", "Order Epson FF-680W"]
assert len(Project.load(p.dir).tasks[2]["files"]) == 3          # attachments moved with their task
arch = [t for t in ws.archive().tasks if t["text"] == "Archive me"]   # Archive written by Swift
assert [(t["from"], t["archived"], t["notes"]) for t in arch] == [("Photo Archive", "2026-11-04", ["kept with it"])], arch
n = next(i for i, t in enumerate(ws.archive().tasks, 1) if t["text"] == "Archive me")
r, back = ops.restore_task(ws, str(n))                   # Python restores what Swift archived
assert back.dir == p.dir and task(p, "Archive me")["notes"] == ["kept with it"]
s = ws.find("Swift Made")[0]
assert s.status == "closed" and s.area == "Digital Infrastructure" and s.goals[0]["text"] == "true"
assert ops.ideas(ws)[-1] == "Idea from iPhone"
ops.add_note(p, "Back on the Mac")
assert Project.load(p.dir).notes[-1].text.endswith("Back on the Mac")
s = ws.find("Swift Made")[0]                             # task moved by Swift, with its note
assert [(t["text"], t["notes"]) for t in s.tasks] == [("Move me across", ["came along"])], s.tasks
m = ops.move_task_to(ws, s, "Move me", Project.load(p.dir))   # and Python moves it back
assert m["notes"] == ["came along"] and not ws.find("Swift Made")[0].tasks
errors = [i for i in lint_workspace(ws) if i.severity == "error"]
assert not errors, errors
assert any(i.code == "L013" for i in lint_workspace(ws)), "iPhone receipt should be flagged for tagging"
print("cross-check OK: Python reads, lints and keeps editing what Swift wrote")
EOF

# A workspace set up from scratch on the iPhone (family member) must be valid for the Mac tools too.
mkdir -p "$TMP/Fresh"
(cd "$HERE/ProjKit" && swift run -q Checks --setup "$TMP/Fresh")
PROJ_ROOT="$TMP/Fresh" PROJ_RECEIPTS="$TMP/Fresh/3 - Receipts" "$REPO/.venv/bin/python" - <<'EOF2'
from projkit.lint import lint_workspace
from projkit.workspace import Workspace
from projkit import ops
ws = Workspace.default()
assert ws.areas() == ["Home", "Personal"], ws.areas()
p = ws.find("Garden")[0]
assert p.area == "Home" and p.goals[0]["text"] == "Plant tomatoes"
assert ops.ideas(ws) == ["Greenhouse"]
errors = [i for i in lint_workspace(ws) if i.severity == "error"]
assert not errors, errors
# the Mac tool can create projects from the iPhone-made template
q = ops.new_project(ws, "Fence", "Personal")
assert q.goals == [] and q.notes[-1].text == "- Project created"
print("cross-check OK: Mac tools accept a workspace set up on the iPhone")
EOF2
