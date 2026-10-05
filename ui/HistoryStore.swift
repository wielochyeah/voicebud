// Read-only access to Python's history.sqlite (SPEC §3). This file never writes to the DB.
// A missing file, a missing table or a broken FTS index all degrade to "empty" or LIKE search.
import Foundation
import SQLite3

struct HistoryEntry: Identifiable, Equatable {
    let id: Int64
    let date: Date
    let mode: Mode
    let app: String
    let raw: String
    let final: String
    let lang: String
    let audioSeconds: Double?
    let totalSeconds: Double?
    let words: Int
}

struct HistoryStats: Equatable {
    var words = 0
    var count = 0
    var avgSeconds: Double?
}

final class HistoryStore {
    static let pageSize = 200

    private let url: URL
    private var db: OpaquePointer?
    /// 1 when `ts` holds Unix seconds (Python `time.time()`), 1000 when it holds milliseconds.
    private var tsScale: Double = 1

    init(url: URL = Paths.history) {
        self.url = url
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Queries

    /// Newest first; `offset` pages through older entries.
    /// dictations, or (ocr) the texts of the Texterkennung: two histories in one table
    private static func kind(_ ocr: Bool, _ p: String = "") -> String { "\(p)mode \(ocr ? "=" : "!=") 'ocr'" }

    func entries(limit: Int = HistoryStore.pageSize, offset: Int = 0, ocr: Bool = false) -> [HistoryEntry] {
        let sql = "SELECT \(Self.columns("")) FROM entries WHERE \(Self.kind(ocr)) ORDER BY ts DESC, id DESC LIMIT ? OFFSET ?"
        return rows(sql, [.int(limit), .int(offset)]) ?? []
    }

    /// FTS5 search over final + raw text, every word prefix-matched (AND). Newest first.
    func search(_ text: String, limit: Int = HistoryStore.pageSize, offset: Int = 0, ocr: Bool = false) -> [HistoryEntry] {
        // Nothing searchable left (only quotes, stars, dashes …): no hit, rather than every row,
        // so the "Treffer" line and the empty state agree with the active query.
        guard let match = Self.ftsQuery(text) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? entries(limit: limit, offset: offset, ocr: ocr) : []
        }
        let fts = """
            SELECT \(Self.columns("e.")) FROM entries_fts JOIN entries e ON e.id = entries_fts.rowid
            WHERE entries_fts MATCH ? AND \(Self.kind(ocr, "e.")) ORDER BY e.ts DESC, e.id DESC LIMIT ? OFFSET ?
            """
        if let found = rows(fts, [.text(match), .int(limit), .int(offset)]) { return found }

        // No FTS table (or a broken one): plain substring search instead of nothing.
        let needle = "%" + text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        let like = """
            SELECT \(Self.columns("")) FROM entries
            WHERE (final LIKE ?1 ESCAPE '\\' OR raw LIKE ?1 ESCAPE '\\') AND \(Self.kind(ocr))
            ORDER BY ts DESC, id DESC LIMIT ?2 OFFSET ?3
            """
        return rows(like, [.text(needle), .int(limit), .int(offset)]) ?? []
    }

    /// Words, entries and mean processing time since local midnight.
    func statsToday(now: Date = Date()) -> HistoryStats {
        guard let db = open() else { return HistoryStats() }
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970 * tsScale
        var stats = HistoryStats()
        _ = step(db, "SELECT COUNT(*), COALESCE(SUM(words), 0), AVG(total_s) FROM entries WHERE ts >= ? AND \(Self.kind(false))",
                 [.double(start)]) { st in
            stats.count = Int(sqlite3_column_int64(st, 0))
            stats.words = Int(sqlite3_column_int64(st, 1))
            stats.avgSeconds = sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : sqlite3_column_double(st, 2)
        }
        return stats
    }

    func count(ocr: Bool = false) -> Int {
        guard let db = open() else { return 0 }
        var n = 0
        _ = step(db, "SELECT COUNT(*) FROM entries WHERE \(Self.kind(ocr))", []) { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    /// Turns free user input into a safe FTS5 expression: letters and digits only, each word
    /// quoted and prefix-matched. Returns nil when nothing searchable is left.
    static func ftsQuery(_ input: String) -> String? {
        let words = input
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { !$0.isEmpty }
            .prefix(12)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - SQLite plumbing

    private enum Bind {
        case int(Int), double(Double), text(String)
    }

    private static func columns(_ p: String) -> String {
        ["id", "ts", "mode", "app", "raw", "final", "lang", "audio_s", "total_s", "words"]
            .map { p + $0 }.joined(separator: ", ")
    }

    private func open() -> OpaquePointer? {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // A WAL reader needs to create/map the -shm file, which a SQLITE_OPEN_READONLY handle cannot
        // do once Python has closed its last connection (the -wal/-shm files are gone then). So the
        // handle is opened read-write and locked down with query_only: this file never writes data.
        var handle: OpaquePointer?
        for flags in [SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX] {
            if sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK { break }
            if let h = handle { sqlite3_close_v2(h) }
            handle = nil
        }
        guard let handle else { return nil }
        sqlite3_exec(handle, "PRAGMA query_only = 1", nil, nil, nil)
        sqlite3_busy_timeout(handle, 400)
        db = handle
        tsScale = 1
        var st: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT MAX(ts) FROM entries", -1, &st, nil) == SQLITE_OK, let st {
            if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_double(st, 0) > 1e11 { tsScale = 1000 }
            sqlite3_finalize(st)
        }
        return handle
    }

    private func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    /// nil = the statement could not run (missing table, broken index); [] = no rows.
    private func rows(_ sql: String, _ binds: [Bind]) -> [HistoryEntry]? {
        guard let db = open() else { return [] }
        var out: [HistoryEntry] = []
        let ok = step(db, sql, binds) { st in out.append(self.entry(st)) }
        return ok ? out : nil
    }

    @discardableResult
    private func step(_ db: OpaquePointer, _ sql: String, _ binds: [Bind], _ row: (OpaquePointer) -> Void) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            reopenIfUnusable(db)
            return false
        }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .int(let v): sqlite3_bind_int64(st, idx, Int64(v))
            case .double(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, transient)
            }
        }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { row(st); continue }
            if rc == SQLITE_DONE { return true }
            reopenIfUnusable(db)
            return false
        }
    }

    /// A missing table is normal (Python has not written yet); anything else that smells like a
    /// stale handle is dropped so the next call opens the file afresh.
    private func reopenIfUnusable(_ db: OpaquePointer) {
        let code = sqlite3_errcode(db)
        if code == SQLITE_CANTOPEN || code == SQLITE_IOERR || code == SQLITE_CORRUPT
            || code == SQLITE_NOTADB || code == SQLITE_READONLY || code == SQLITE_ERROR {
            close()
        }
    }

    private func entry(_ st: OpaquePointer) -> HistoryEntry {
        func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(st, i) else { return "" }
            return String(cString: c)
        }
        func real(_ i: Int32) -> Double? {
            sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i)
        }
        return HistoryEntry(
            id: sqlite3_column_int64(st, 0),
            date: Date(timeIntervalSince1970: sqlite3_column_double(st, 1) / tsScale),
            mode: Mode(rawValue: text(2)) ?? .dictate,
            app: text(3),
            raw: text(4),
            final: text(5),
            lang: text(6),
            audioSeconds: real(7),
            totalSeconds: real(8),
            words: Int(sqlite3_column_int64(st, 9)))
    }
}
