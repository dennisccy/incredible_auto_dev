"""Todo — EVO-3 benchmark fixture, BARE scaffold.

Deliberately implements NO journey from docs/goal.md (no add, no toggle, no
filter): the benchmark measures the goal-mode chain BUILDING those features.
This file provides only the shell page, the health endpoint, and the
JSON-file store primitive the features will grow on; mutations are the
chain's work.

Run: .venv/bin/python app.py  ->  http://127.0.0.1:5177/
"""
import json
from pathlib import Path

from flask import Flask, jsonify, render_template

BASE_DIR = Path(__file__).resolve().parent

app = Flask(__name__)
app.config.setdefault("DATA_FILE", str(BASE_DIR / "todos.json"))


def load_todos():
    """Return the todo list, creating the JSON store on first use."""
    store = Path(app.config["DATA_FILE"])
    if not store.exists():
        store.write_text("[]", encoding="utf-8")
    return json.loads(store.read_text(encoding="utf-8"))


@app.route("/")
def index():
    load_todos()  # materialize the store at runtime; nothing rendered from it yet
    return render_template("index.html")


@app.route("/health")
def health():
    return jsonify(status="ok")


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5177)
