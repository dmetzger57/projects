import subprocess
import sys
from pathlib import Path

from fastapi.testclient import TestClient

import projkit
from projkit.about import version_string
from projkit.web.app import create_app
from projkit.workspace import Workspace

ROOT = Path(__file__).resolve().parent.parent


def test_version_files_agree():
    r = subprocess.run([sys.executable, str(ROOT / "scripts/version.py"), "check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout
    assert projkit.__version__ == (ROOT / "VERSION").read_text().strip()


def test_version_shown_in_cli_and_web(tmp_path):
    from typer.testing import CliRunner
    from projkit.cli import app
    out = CliRunner().invoke(app, ["--version"]).output
    assert out.strip() == f"proj {version_string()}"
    (tmp_path / "Projects").mkdir()
    page = TestClient(create_app(Workspace(tmp_path / "Projects", tmp_path))).get("/").text
    assert f"version {version_string()}" in page
