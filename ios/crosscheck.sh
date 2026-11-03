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
