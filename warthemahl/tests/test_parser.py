"""Parser tests for bin/warthemahl-menu against a captured copy of the real page.

Run: python3 -m unittest discover -s tests -v   (from the plugin directory)
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "bin", "warthemahl-menu")
FIXTURE = os.path.join(HERE, "fixtures", "speisekarte.html")


def load_helper():
    spec = importlib.util.spec_from_loader("warthemahl_menu", None)
    module = importlib.util.module_from_spec(spec)
    with open(HELPER, encoding="utf-8") as fh:
        exec(compile(fh.read(), HELPER, "exec"), module.__dict__)
    return module


wm = load_helper()


class ParseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(FIXTURE, encoding="utf-8") as fh:
            cls.result = wm.parse(fh.read())

    def test_every_weekday_of_the_published_week_is_found(self):
        weekdays = [d["weekday"] for d in self.result["days"]]
        self.assertEqual(weekdays, ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag"])

    def test_each_day_carries_a_full_iso_date_for_the_today_highlight(self):
        dates = [d.get("date") for d in self.result["days"]]
        self.assertEqual(dates, ["2026-08-24", "2026-08-25", "2026-08-26",
                                 "2026-08-27", "2026-08-28"])

    def test_days_split_across_several_strong_tags_still_parse(self):
        # The page bolds "Freitag, 28", ". ", "August" and "2026" separately.
        friday = self.result["days"][-1]
        self.assertEqual(friday["day"], 28)
        self.assertEqual(friday["dateLabel"], "28. Aug")
        self.assertEqual(friday["year"], 2026)

    def test_both_dishes_survive_with_their_sup_annotations_inline(self):
        tuesday = self.result["days"][1]
        self.assertEqual(len(tuesday["dishes"]), 2)
        self.assertEqual(tuesday["dishes"][0],
                         "Schnitzel (Hähnchen), Kaiserrahmgemüse und Petersilienkartoffeln")
        self.assertIn("Curry", tuesday["dishes"][1])

    def test_the_split_footnote_marker_is_rejoined_not_left_as_a_stray_line(self):
        # The page marks footnotes as <sup>(</sup>*<sup>)</sup>.
        wednesday = self.result["days"][2]
        self.assertTrue(wednesday["dishes"][0].endswith("Butterspätzle (*)"))
        self.assertNotIn("*", wednesday["dishes"][1])

    def test_navigation_and_filler_paragraphs_are_not_mistaken_for_days(self):
        self.assertEqual(len(self.result["days"]), 5)
        for day in self.result["days"]:
            self.assertTrue(all(dish.strip() for dish in day["dishes"]))

    def test_pdf_and_week_label_back_the_panel_footer(self):
        self.assertTrue(self.result["pdfUrl"].endswith("Speisekarte_24-08-2026.pdf"))
        self.assertEqual(self.result["weekLabel"], "24.–28. Aug 2026")

    def test_a_week_spanning_two_months_names_both(self):
        days = [
            {"weekday": "Montag", "day": 30, "month": 3, "year": 2026},
            {"weekday": "Freitag", "day": 3, "month": 4, "year": 2026},
        ]
        self.assertEqual(wm.week_label(days), "30. Mär – 3. Apr 2026")

    def test_a_page_without_a_menu_yields_no_days_rather_than_junk(self):
        self.assertEqual(wm.parse("<html><body><p>Wir haben Betriebsferien.</p></body></html>")["days"], [])


class CacheTest(unittest.TestCase):
    """The helper is the panel's only data path, so it must always print one
    JSON object and exit 0 -- including when the network is gone."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.env = dict(os.environ, XDG_CACHE_HOME=self.tmp)

    def run_helper(self, *args, env=None):
        proc = subprocess.run([sys.executable, HELPER, *args], env=env or self.env,
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def seed_cache(self, fetched_at):
        with open(FIXTURE, encoding="utf-8") as fh:
            data = wm.parse(fh.read())
        data.update({"fetchedAt": fetched_at, "stale": False, "error": "", "sourceUrl": wm.URL})
        path = os.path.join(self.tmp, "dms", "warthemahl-menu.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False)
        return data

    def test_a_fresh_cache_is_served_without_touching_the_network(self):
        self.seed_cache(int(time.time()))
        # Point the helper at an unroutable host: a network call would fail the
        # assertion below, so passing proves the cache short-circuited it.
        env = dict(self.env, http_proxy="http://127.0.0.1:9", https_proxy="http://127.0.0.1:9")
        result = self.run_helper("--max-age", "3600", env=env)
        self.assertEqual(len(result["days"]), 5)
        self.assertFalse(result["stale"])
        self.assertEqual(result["error"], "")

    def test_an_unreachable_site_falls_back_to_the_cache_and_flags_it_stale(self):
        self.seed_cache(int(time.time()) - 86400)
        env = dict(self.env, https_proxy="http://127.0.0.1:9", http_proxy="http://127.0.0.1:9")
        result = self.run_helper("--max-age", "60", env=env)
        self.assertEqual(len(result["days"]), 5)
        self.assertTrue(result["stale"])
        self.assertNotEqual(result["error"], "")

    def test_an_unreachable_site_with_no_cache_reports_the_error_and_still_exits_zero(self):
        env = dict(self.env, https_proxy="http://127.0.0.1:9", http_proxy="http://127.0.0.1:9")
        result = self.run_helper(env=env)
        self.assertEqual(result["days"], [])
        self.assertNotEqual(result["error"], "")
        self.assertEqual(result["sourceUrl"], wm.URL)


if __name__ == "__main__":
    unittest.main()
