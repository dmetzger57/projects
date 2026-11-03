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
assert p.title == "Photo Archive" and p.status == "on-hold"
assert p.goals[0]["done"] is True and str(p.goals[0]["done_on"]) == datetime.date.today().isoformat()
assert p.goals[-1]["text"] == "Buy a scanner: Epson FF-680W"
assert p.links[-1] == {"title": 'Example: "quoted"', "url": "https://example.com/a?b=c#d"}
assert p.receipts[0]["amount"] == 649.99 and p.total_cost == 649.99
assert p.section("Description") == "Consolidate **all** photos.\n\n- prints\n- slides"
assert p.notes[-1].text.endswith("- Edited on iPhone\n  second line")
assert p.tasks == [{"text": "Move me to the top", "done": False}, {"text": "Order Epson FF-680W", "done": False},
                   {"text": "Pick storage", "done": True}], p.tasks
assert [(f["name"], f["target"], f["kind"]) for f in p.files] == [
    ("Scanner manual", "Documents/Manuals/Epson FF-680W.pdf", "file"),
    ("Plan", "https://docs.google.com/document/d/abc/edit?tab=t.0", "url")], p.files
ops.edit_file(p, "Plan", name="Planning doc")
assert Project.load(p.dir).files[1]["name"] == "Planning doc"
ops.set_task(p, "Order", True)
ops.move_task(p, "Pick", 1)
assert [t["text"] for t in Project.load(p.dir).tasks] == ["Pick storage", "Move me to the top", "Order Epson FF-680W"]
s = ws.find("Swift Made")[0]
assert s.status == "closed" and s.area == "Digital Infrastructure" and s.goals[0]["text"] == "true"
assert ops.ideas(ws)[-1] == "Idea from iPhone"
ops.add_note(p, "Back on the Mac")
assert Project.load(p.dir).notes[-1].text.endswith("Back on the Mac")
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
