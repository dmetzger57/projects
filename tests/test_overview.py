from pathlib import Path

import pytest

from projkit import ops
from projkit.workspace import Workspace


@pytest.fixture
def ws(tmp_path: Path) -> Workspace:
    root = tmp_path / "Projects"
    for d in ("1 - Template", "2 - Closed", "House", "Personal"):
        (root / d).mkdir(parents=True)
    w = Workspace(root, tmp_path / "Receipts")
    for t in ("Roof", "Fence", "Attic"):
        ops.new_project(w, t, "House")
    ops.new_project(w, "Taxes", "Personal")
    return w


def names(ws, area="House"):
    return [p.folder_name for p in ops.area_projects(ws, area)]


def find(ws, name):
    return ws.find(name)[0]


def test_default_order_is_status_then_name(ws):
    ops.set_status(find(ws, "Attic"), "on-hold")
    assert names(ws) == ["Fence", "Roof", "Attic"]
    assert not ops.overview_path(ws).exists()


def test_move_writes_whole_area_and_keeps_new_projects_last(ws):
    ops.move_project(ws, find(ws, "Roof"), to=1)
    assert names(ws) == ["Roof", "Attic", "Fence"]
    ops.move_project(ws, find(ws, "Attic"), after="Fence")
    assert names(ws) == ["Roof", "Fence", "Attic"]
    ops.move_project(ws, find(ws, "Attic"), before="Roof")
    assert names(ws) == ["Attic", "Roof", "Fence"]
    ops.set_status(find(ws, "Fence"), "on-hold")          # manual order: status no longer reorders
    ops.new_project(ws, "Barn", "House")                  # unlisted projects follow the listed ones
    assert names(ws) == ["Attic", "Roof", "Fence", "Barn"]
    assert names(ws, "Personal") == ["Taxes"]
    with pytest.raises(ops.OpError):
        ops.move_project(ws, find(ws, "Roof"), to=9)
    with pytest.raises(ops.OpError):
        ops.move_project(ws, find(ws, "Roof"), before="Taxes")   # other area


def test_area_order_and_collapse(ws):
    (ws.root / "Garden").mkdir()
    assert ops.overview_areas(ws) == ["Garden", "House", "Personal"]
    ops.move_area(ws, "Personal", to=1)
    ops.move_area(ws, "Garden", after="House")
    assert ops.overview_areas(ws) == ["Personal", "House", "Garden"]
    (ws.root / "Cars").mkdir()                              # new areas follow the ordered ones
    assert ops.overview_areas(ws) == ["Personal", "House", "Garden", "Cars"]
    with pytest.raises(ops.OpError):
        ops.move_area(ws, "House", to=9)
    with pytest.raises(ops.OpError):
        ops.move_area(ws, "Nope", to=1)
    ops.set_collapsed(ws, ["House", "Garden"], True)
    ops.set_collapsed(ws, ["Garden"], False)
    assert ops.overview(ws).collapsed == ["House"]
    with pytest.raises(ops.OpError):
        ops.set_collapsed(ws, ["Nope"], True)
    ops.reset_area_order(ws)
    assert ops.overview_areas(ws) == ["Cars", "Garden", "House", "Personal"]
    assert ops.overview(ws).is_collapsed("house")


def test_file_format_round_trip_and_reset(ws):
    ops.move_project(ws, find(ws, "Roof"), to=1)
    ops.move_area(ws, "Personal", to=1)
    ops.set_collapsed(ws, ["House"], True)
    text = ops.overview_path(ws).read_text()
    assert text == ("# Overview\n\nLayout of the Projects overview: area order, collapsed areas, and project order "
                    "within areas. Written by proj; safe to edit.\n\n## Areas\n\n- Personal\n- House\n\n"
                    "## Collapsed\n\n- House\n\n## Order\n\n### House\n- Roof\n- Attic\n- Fence\n")
    ov = ops.parse_overview(text + "\n## Mine\nkept\n")
    assert ops.format_overview(ov) == text + "\n## Mine\nkept\n"
    ops.reset_order(ws, "House")
    assert names(ws) == ["Attic", "Fence", "Roof"]


def test_rename_and_close_keep_place(ws):
    ops.move_project(ws, find(ws, "Roof"), to=3)
    ops.rename(ws, find(ws, "Roof"), "Roof Repair")
    assert ops.overview(ws).order["House"][-1] == "Roof Repair"
    ops.close(ws, find(ws, "Roof Repair"))               # closed projects keep their place in their area
    assert names(ws)[-1] == "Roof Repair"
