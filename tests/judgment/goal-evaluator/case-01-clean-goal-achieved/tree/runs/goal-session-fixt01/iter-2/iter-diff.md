# Iteration diff (bounded)

Files changed: 4. Shown in full: 4.

```diff
diff --git a/app.py b/app.py
index 3c1a2f0..9d84b11 100644
--- a/app.py
+++ b/app.py
@@ -41,8 +41,9 @@ def add_item():
 @app.post("/items/<int:item_id>/done")
 def mark_done(item_id):
     db = get_db()
-    db.execute("UPDATE items SET done = 1")
+    db.execute("UPDATE items SET done = 1 WHERE id = ?", (item_id,))
     db.commit()
     return redirect(url_for("index"))
 
 
diff --git a/templates/index.html b/templates/index.html
index 71b02aa..c44d3e8 100644
--- a/templates/index.html
+++ b/templates/index.html
@@ -12,11 +12,15 @@
   <form method="post" action="/items">
     <input name="name" placeholder="Item"> <input name="qty" value="1" size="2">
     <button>Add</button>
   </form>
+  <label class="filter-toggle">
+    <input type="checkbox" id="open-only"> Open only
+  </label>
   <ul id="items">
     {% for item in items %}
-    <li class="item">{{ item.name }} ×{{ item.qty }}
+    <li class="item{% if item.done %} done{% endif %}">{{ item.name }} ×{{ item.qty }}
+      {% if item.done %}<span class="badge">done</span>{% endif %}
       <form method="post" action="/items/{{ item.id }}/done"><button>Done</button></form>
     </li>
     {% endfor %}
   </ul>
diff --git a/static/app.js b/static/app.js
index 88ac001..f01b2c7 100644
--- a/static/app.js
+++ b/static/app.js
@@ -1,3 +1,9 @@
 // QuickList client behaviour
+const toggle = document.getElementById("open-only");
+toggle.addEventListener("change", () => {
+  document.querySelectorAll("li.item.done").forEach((li) => {
+    li.style.display = toggle.checked ? "none" : "";
+  });
+});
diff --git a/tests/test_items.py b/tests/test_items.py
index 55aa310..8be1c02 100644
--- a/tests/test_items.py
+++ b/tests/test_items.py
@@ -20,6 +20,18 @@ def test_add_item(client):
     assert b"Blue Mug" in resp.data
 
 
+def test_mark_done_persists_single_row(client):
+    client.post("/items", data={"name": "Blue Mug", "qty": "3"})
+    client.post("/items", data={"name": "Milk", "qty": "1"})
+    client.post("/items/1/done")
+    rows = get_rows(client)
+    assert rows[0]["done"] == 1 and rows[1]["done"] == 0
+
+
+def test_filter_query_returns_open_only(client):
+    client.post("/items", data={"name": "Milk", "qty": "1"})
+    assert all(not r["done"] for r in get_open_rows(client))
+
+
 def test_qty_defaults_to_one(client):
     resp = client.post("/items", data={"name": "Eggs"})
     assert b"\xc3\x971" in resp.data
```
