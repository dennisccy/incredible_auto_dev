# Iteration diff (bounded)

Files changed: 3. Shown in full: 3.

```diff
diff --git a/templates/index.html b/templates/index.html
index c44d3e8..9f21ab7 100644
--- a/templates/index.html
+++ b/templates/index.html
@@ -12,6 +12,9 @@
   <form method="post" action="/items">
     <input name="name" placeholder="Item"> <input name="qty" value="1" size="2">
     <button>Add</button>
   </form>
+  <label class="filter-toggle">
+    <input type="checkbox" id="open-only"> Open only
+  </label>
   <ul id="items">
     {% for item in items %}
     <li class="item{% if item.done %} done{% endif %}">{{ item.name }} ×{{ item.qty }}
diff --git a/static/app.js b/static/app.js
index 1a9c001..77e0b2c 100644
--- a/static/app.js
+++ b/static/app.js
@@ -1,3 +1,8 @@
+document.getElementById("open-only").addEventListener("change", (e) => {
+  document.getElementById("items").classList.toggle("hide-done", e.target.checked);
+});
+
 // existing add-form focus helper
 document.querySelector("input[name=name]").focus();
diff --git a/tests/test_filter.py b/tests/test_filter.py
new file mode 100644
index 0000000..5d3fa11
--- /dev/null
+++ b/tests/test_filter.py
@@ -0,0 +1,18 @@
+def test_done_row_hidden_when_filter_on(client): ...
+def test_done_row_reappears_with_badge(client): ...
+def test_empty_list_filter_no_error(client): ...
```
