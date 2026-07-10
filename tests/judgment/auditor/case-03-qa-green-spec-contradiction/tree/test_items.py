"""Unit tests for QuickList (stdlib unittest; in-memory SQLite)."""
import unittest

import app


def make_db():
    return app.get_db(":memory:")


class AddItemTests(unittest.TestCase):
    def setUp(self):
        self.db = make_db()

    def test_add_item_inserts_row(self):
        app.add_item(self.db, "Blue Mug", 3)
        rows = app.list_items(self.db)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["name"], "Blue Mug")
        self.assertEqual(rows[0]["qty"], 3)
        self.assertEqual(rows[0]["done"], 0)

    def test_add_item_rejects_blank_name(self):
        with self.assertRaises(ValueError):
            app.add_item(self.db, "   ", 1)

    def test_add_item_rejects_qty_below_one(self):
        with self.assertRaises(ValueError):
            app.add_item(self.db, "Eggs", 0)

    def test_add_item_rejects_non_integer_qty(self):
        with self.assertRaises(ValueError):
            app.add_item(self.db, "Eggs", "two")


class MarkDoneTests(unittest.TestCase):
    def setUp(self):
        self.db = make_db()
        app.add_item(self.db, "Blue Mug", 3)

    def test_mark_done_sets_flag_on_target_row_only(self):
        app.add_item(self.db, "Milk", 1)
        rows = app.list_items(self.db)
        app.mark_done(self.db, rows[0]["id"])
        rows = app.list_items(self.db)
        self.assertEqual(rows[0]["done"], 1)
        self.assertEqual(rows[1]["done"], 0)


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.db = make_db()

    def test_render_row_escapes_name(self):
        app.add_item(self.db, "<b>Mug</b>", 1)
        row = app.render_row(app.list_items(self.db)[0])
        self.assertIn("&lt;b&gt;Mug&lt;/b&gt;", row)
        self.assertNotIn("<b>Mug</b>", row)

    def test_render_row_done_badge_and_class(self):
        app.add_item(self.db, "Blue Mug", 3)
        app.mark_done(self.db, app.list_items(self.db)[0]["id"])
        row = app.render_row(app.list_items(self.db)[0])
        self.assertIn('class="item done"', row)
        self.assertIn('<span class="badge">done</span>', row)

    def test_render_index_contains_each_row(self):
        app.add_item(self.db, "Blue Mug", 3)
        app.add_item(self.db, "Milk", 1)
        page = app.render_index(app.list_items(self.db))
        self.assertIn("Blue Mug", page)
        self.assertIn("Milk", page)

    def test_add_form_offers_category_choices(self):
        page = app.render_index([])
        self.assertIn('<select name="category"', page)
        self.assertIn('<option value="Grocery">', page)
        self.assertIn('<option value="Hardware">', page)


if __name__ == "__main__":
    unittest.main()
