from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


@pytest.fixture()
def check_env():
    spec = importlib.util.spec_from_file_location("check_env", SCRIPTS / "check_env.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_runs_and_reports_python(check_env, capsys: pytest.CaptureFixture[str]) -> None:
    check_env.main()
    out = capsys.readouterr().out
    assert f"Python {sys.version.split()[0]}" in out
    assert "Base stack" in out


def test_parse_requirements_strips_extras_and_comments(check_env, tmp_path: Path) -> None:
    req = tmp_path / "req.txt"
    req.write_text("# comment\nuvicorn[standard]==0.1.0\nnumpy\n-r other.txt\n")
    assert check_env.parse_requirements(req) == [("uvicorn", "0.1.0"), ("numpy", None)]
