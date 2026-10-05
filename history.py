"""History writer: one row per take in history.sqlite (schema: ui/SPEC.md §3).

Python is the only writer; the Swift hub reads concurrently, hence WAL mode. The FTS5 index is an
external-content table kept in sync by triggers, so whoever deletes or edits a row also updates
the search index."""
import sqlite3
import threading
import time

import settings

SCHEMA = """
CREATE TABLE IF NOT EXISTS entries(id INTEGER PRIMARY KEY, ts REAL NOT NULL, mode TEXT NOT NULL,
  app TEXT, raw TEXT, final TEXT, lang TEXT, audio_s REAL, stt_s REAL, llm_s REAL,
  total_s REAL, words INTEGER);
CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(final, raw, content='entries', content_rowid='id');
CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
  INSERT INTO entries_fts(rowid, final, raw) VALUES (new.id, new.final, new.raw);
END;
CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
  INSERT INTO entries_fts(entries_fts, rowid, final, raw) VALUES ('delete', old.id, old.final, old.raw);
END;
CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE ON entries BEGIN
  INSERT INTO entries_fts(entries_fts, rowid, final, raw) VALUES ('delete', old.id, old.final, old.raw);
  INSERT INTO entries_fts(rowid, final, raw) VALUES (new.id, new.final, new.raw);
END;
"""
COLUMNS = ("ts", "mode", "app", "raw", "final", "lang", "audio_s", "stt_s", "llm_s", "total_s", "words")


class History:
    def __init__(self, path=None):
        self.path = path or settings.data_dir() / "history.sqlite"
        self._lock = threading.Lock()
        self._db = sqlite3.connect(str(self.path), check_same_thread=False, timeout=5)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=NORMAL")
        self._db.executescript(SCHEMA)
        self._db.commit()

    def add(self, **row):
        """Insert one take; missing columns are NULL, `ts` defaults to now. Returns the row id."""
        row.setdefault("ts", time.time())
        values = [row.get(c) for c in COLUMNS]
        with self._lock:
            cur = self._db.execute(
                f"INSERT INTO entries({', '.join(COLUMNS)}) VALUES ({', '.join('?' * len(COLUMNS))})",
                values)
            self._db.commit()
            return cur.lastrowid

    def search(self, query, limit=50):
        """FTS lookup, newest first (the hub has its own reader; this is for tests and tools)."""
        with self._lock:
            return self._db.execute(
                "SELECT e.id, e.final FROM entries_fts f JOIN entries e ON e.id = f.rowid "
                "WHERE entries_fts MATCH ? ORDER BY e.ts DESC LIMIT ?", (query, limit)).fetchall()

    def close(self):
        with self._lock:
            try:
                self._db.close()
            except sqlite3.Error:
                pass
