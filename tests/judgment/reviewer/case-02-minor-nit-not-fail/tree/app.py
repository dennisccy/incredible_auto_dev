#!/usr/bin/env python3
"""QuickList — single-user, local-first shopping list.

Python stdlib + SQLite + vanilla JS only (see docs/goal.md constraints).
Run with: python3 app.py  ->  http://127.0.0.1:8080/
"""
import html
import re
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "quicklist.db"
TEMPLATE_PATH = BASE_DIR / "templates" / "index.html"
STATIC_DIR = BASE_DIR / "static"

SCHEMA = (
    "CREATE TABLE IF NOT EXISTS items ("
    " id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " name TEXT NOT NULL,"
    " qty INTEGER NOT NULL,"
    " done INTEGER NOT NULL DEFAULT 0)"
)


def get_db(path=None):
    """Open (and initialize) the SQLite database."""
    conn = sqlite3.connect(str(path or DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute(SCHEMA)
    return conn


def add_item(db, name, qty):
    """Insert an item. Server-side validation: non-empty name, integer qty >= 1."""
    name = (name or "").strip()
    if not name:
        raise ValueError("name must not be empty")
    if not isinstance(qty, int) or qty < 1:
        raise ValueError("qty must be an integer >= 1")
    db.execute("INSERT INTO items (name, qty) VALUES (?, ?)", (name, qty))
    db.commit()


def mark_done(db, item_id):
    """Set the done flag on one item."""
    db.execute("UPDATE items SET done = 1 WHERE id = ?", (item_id,))
    db.commit()


def clear_done(db):
    """Delete every done item (J-04). Returns the number of rows removed."""
    cur = db.execute("DELETE FROM items WHERE done = 1")
    db.commit()
    print(f"[debug] clear_done removed {cur.rowcount} rows")
    return cur.rowcount


def list_items(db):
    """All items, oldest first."""
    return db.execute("SELECT id, name, qty, done FROM items ORDER BY id").fetchall()


def render_row(item):
    """One <li> per item; done rows carry the `done` class and badge (J-02)."""
    css = "item done" if item["done"] else "item"
    badge = ' <span class="badge">done</span>' if item["done"] else ""
    return (
        f'<li class="{css}" data-id="{item["id"]}">'
        f'{html.escape(item["name"])} × {item["qty"]}{badge}'
        f' <form class="inline" method="post" action="/items/{item["id"]}/done">'
        f"<button>Done</button></form></li>"
    )


def render_index(items):
    """Render the full index page from the template."""
    rows = "\n".join(render_row(i) for i in items)
    return TEMPLATE_PATH.read_text(encoding="utf-8").replace("<!--ROWS-->", rows)


class QuickListHandler(BaseHTTPRequestHandler):
    def _send_html(self, status, body):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, location):
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def _form(self):
        length = int(self.headers.get("Content-Length") or 0)
        return parse_qs(self.rfile.read(length).decode("utf-8"))

    def do_GET(self):
        if self.path == "/":
            self._send_html(200, render_index(list_items(get_db())))
        elif self.path == "/static/app.js":
            data = (STATIC_DIR / "app.js").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_error(404)

    def do_POST(self):
        form = self._form()
        if self.path == "/items":
            try:
                qty = int(form.get("qty", [""])[0])
            except ValueError:
                self.send_error(400, "qty must be an integer")
                return
            try:
                add_item(get_db(), form.get("name", [""])[0], qty)
            except ValueError as exc:
                self.send_error(400, str(exc))
                return
            self._redirect("/")
        elif self.path == "/items/clear-done":
            clear_done(get_db())
            self._redirect("/")
        elif m := re.fullmatch(r"/items/(\d+)/done", self.path):
            mark_done(get_db(), int(m.group(1)))
            self._redirect("/")
        else:
            self.send_error(404)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 8080), QuickListHandler)
    print("QuickList running on http://127.0.0.1:8080/")
    server.serve_forever()


if __name__ == "__main__":
    main()
