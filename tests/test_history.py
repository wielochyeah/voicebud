import json
import sqlite3
import tempfile
import threading
import unittest
from pathlib import Path

import _util  # noqa: F401
import settings
from history import COLUMNS, History


class HistoryTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="vb-hist-"))
        self.h = History(self.dir / "history.sqlite")

    def tearDown(self):
        self.h.close()

    def test_schema_wal_and_fts(self):
        rid = self.h.add(mode="dictate", app="Mail", raw="ähm hallo Frau Becker", final="Hallo Frau Becker,",
                         lang="de", audio_s=2.1, stt_s=0.2, llm_s=0.0, total_s=0.3, words=3)
        self.h.add(mode="prompt", app="Safari", raw="schreib eine mail", final="Rolle: …", lang="de",
                   audio_s=3.0, stt_s=0.3, llm_s=1.2, total_s=1.6, words=2)
        # a second connection (like the Swift hub) sees committed rows while we hold ours open
        ro = sqlite3.connect(f"file:{self.dir / 'history.sqlite'}?mode=ro", uri=True)
        self.assertEqual(ro.execute("PRAGMA journal_mode").fetchone()[0], "wal")
        cols = [r[1] for r in ro.execute("PRAGMA table_info(entries)")]
        self.assertEqual(cols, ["id", *COLUMNS])
        self.assertEqual(ro.execute("SELECT COUNT(*) FROM entries").fetchone()[0], 2)
        hits = ro.execute("SELECT rowid FROM entries_fts WHERE entries_fts MATCH 'Becker'").fetchall()
        self.assertEqual(hits, [(rid,)])
        hits = ro.execute("SELECT rowid FROM entries_fts WHERE entries_fts MATCH 'raw:ähm'").fetchall()
        self.assertEqual(hits, [(rid,)])
        ro.close()

    def test_triggers_keep_index_in_sync(self):
        rid = self.h.add(mode="dictate", raw="alpha", final="Alpha Beta", words=2)
        self.assertEqual(len(self.h.search("Beta")), 1)
        db = sqlite3.connect(self.dir / "history.sqlite")
        db.execute("UPDATE entries SET final='Gamma' WHERE id=?", (rid,))
        db.commit()
        self.assertEqual(len(self.h.search("Beta")), 0)
        self.assertEqual(len(self.h.search("Gamma")), 1)
        db.execute("DELETE FROM entries WHERE id=?", (rid,))
        db.commit()
        db.close()
        self.assertEqual(len(self.h.search("Gamma")), 0)

    def test_threaded_inserts(self):
        threads = [threading.Thread(target=lambda i=i: self.h.add(mode="dictate", final=f"take {i}", words=2))
                   for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(self.h.search("take", limit=100)), 20)

    def test_reopen_existing_db(self):
        self.h.add(mode="dictate", final="eins", words=1)
        self.h.close()
        self.h = History(self.dir / "history.sqlite")
        self.assertEqual(len(self.h.search("eins")), 1)


class SettingsTest(unittest.TestCase):
    def test_defaults_and_bad_values(self):
        path = settings.data_dir() / "settings.json"
        path.write_text(json.dumps({"keepModelsLoaded": "yes", "confirmSeconds": 3, "islandStyle": "live",
                                    "futureKey": [1, 2]}))
        s = settings.load()
        self.assertFalse(s["keepModelsLoaded"])           # wrong type -> default
        self.assertEqual(s["confirmSeconds"], 3)          # int accepted for a float
        # SPEC §0: old "live" = island at the notch with live text
        self.assertEqual((s["islandStyle"], s["liveText"]), ("insel", True))
        self.assertEqual(s["futureKey"], [1, 2])          # unknown keys survive
        for stored, expected in [({"islandStyle": "kompakt"}, ("insel", False)),
                                 ({"islandStyle": "kapsel"}, ("kapsel", False)),
                                 ({"islandStyle": "kapsel", "liveText": True}, ("kapsel", True)),
                                 ({"islandStyle": "live", "liveText": False}, ("insel", False)),
                                 ({}, ("insel", False))]:
            path.write_text(json.dumps(stored))
            s = settings.load()
            self.assertEqual((s["islandStyle"], s["liveText"]), expected, stored)
        path.write_text("{not json")
        self.assertEqual(settings.load(), settings.DEFAULTS)
        path.unlink()
        self.assertEqual(settings.load(), settings.DEFAULTS)


if __name__ == "__main__":
    unittest.main()
