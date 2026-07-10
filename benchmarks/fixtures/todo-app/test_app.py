"""Scaffold tests — green on the BARE fixture (no journey features yet).

These three tests pin the scaffold contract the goal-mode chain starts from:
the app imports, the shell page serves, the health endpoint answers, and the
JSON store materializes at runtime. The chain grows this file as it
implements the journeys in docs/goal.md.
"""
import pytest

import app as todo_app


@pytest.fixture()
def client(tmp_path):
    todo_app.app.config["DATA_FILE"] = str(tmp_path / "todos.json")
    todo_app.app.config["TESTING"] = True
    with todo_app.app.test_client() as c:
        yield c


def test_app_imports():
    assert todo_app.app.name == "app"


def test_index_serves_shell_and_creates_store(client, tmp_path):
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"Todo" in resp.data
    assert (tmp_path / "todos.json").exists()


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}
