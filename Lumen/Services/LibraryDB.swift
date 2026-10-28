import Foundation
import SQLite3

/// Indexed history, bookmarks, and per-host zoom. Queries stay on the caller thread.
final class LibraryDB {
    static let shared: LibraryDB = {
        let path = (try? JSONStore.url("library.sqlite").path) ?? ":memory:"
        return LibraryDB(path: path)
    }()

    static let historyCap = 1500
    private var db: OpaquePointer?

    init(path: String) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else { return }
        db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        exec("""
        CREATE TABLE IF NOT EXISTS history (
          id TEXT PRIMARY KEY,
          url TEXT NOT NULL UNIQUE,
          title TEXT NOT NULL,
          host TEXT NOT NULL,
          visit_count INTEGER NOT NULL,
          last_visit REAL NOT NULL,
          fts_rowid INTEGER
        );
        CREATE INDEX IF NOT EXISTS history_last ON history(last_visit);
        CREATE INDEX IF NOT EXISTS history_host ON history(host);
        CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(title, host, url, tokenize='unicode61');
        CREATE TABLE IF NOT EXISTS bookmark (
          id TEXT PRIMARY KEY,
          url TEXT NOT NULL UNIQUE,
          title TEXT NOT NULL,
          host TEXT NOT NULL,
          created REAL NOT NULL,
          fts_rowid INTEGER
        );
        CREATE INDEX IF NOT EXISTS bookmark_created ON bookmark(created);
        CREATE VIRTUAL TABLE IF NOT EXISTS bookmark_fts USING fts5(title, host, url, tokenize='unicode61');
        CREATE TABLE IF NOT EXISTS zoom (
          host TEXT PRIMARY KEY,
          factor REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """)
        importJSONIfNeeded()
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    func recordHistory(url: URL, title: String) {
        guard let normalized = HistoryStore.normalize(url), let host = url.host?.lowercased(), !host.isEmpty else { return }
        let absolute = normalized.absoluteString
        let trimmed = String((title.isEmpty ? host : title).prefix(180))
        let now = Date().timeIntervalSince1970
        if let existing = historyRow(url: absolute) {
            let count = existing.visitCount + 1
            let fts = replaceFTS(table: "history_fts", rowid: existing.ftsRow, title: trimmed, host: host, url: absolute)
            run("UPDATE history SET title = ?, host = ?, visit_count = ?, last_visit = ?, fts_rowid = ? WHERE url = ?") { stmt in
                bind(stmt, 1, trimmed)
                bind(stmt, 2, host)
                sqlite3_bind_int(stmt, 3, Int32(count))
                sqlite3_bind_double(stmt, 4, now)
                sqlite3_bind_int64(stmt, 5, fts)
                bind(stmt, 6, absolute)
            }
        } else {
            let fts = replaceFTS(table: "history_fts", rowid: nil, title: trimmed, host: host, url: absolute)
            run("INSERT INTO history (id, url, title, host, visit_count, last_visit, fts_rowid) VALUES (?, ?, ?, ?, 1, ?, ?)") { stmt in
                bind(stmt, 1, UUID().uuidString)
                bind(stmt, 2, absolute)
                bind(stmt, 3, trimmed)
                bind(stmt, 4, host)
                sqlite3_bind_double(stmt, 5, now)
                sqlite3_bind_int64(stmt, 6, fts)
            }
        }
        evictHistory()
    }

    func recentHistory(limit: Int) -> [HistoryEntry] {
        queryHistory("SELECT id, url, title, host, visit_count, last_visit FROM history ORDER BY last_visit DESC LIMIT ?", limit: limit)
    }

    func searchHistory(_ raw: String, limit: Int) -> [HistoryEntry] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recentHistory(limit: limit) }
        if let match = LibrarySearch.ftsQuery(trimmed) {
            let sql = """
            SELECT h.id, h.url, h.title, h.host, h.visit_count, h.last_visit
            FROM history_fts
            JOIN history h ON h.url = history_fts.url
            WHERE history_fts MATCH ?
            ORDER BY h.last_visit DESC
            LIMIT ?
            """
            let found = queryHistory(sql, match: match, limit: limit)
            if !found.isEmpty { return found }
        }
        return likeHistory(trimmed, limit: limit)
    }

    func deleteHistory(_ id: UUID) {
        if let row = historyRow(id: id.uuidString) {
            deleteFTS(table: "history_fts", rowid: row.ftsRow)
        }
        run("DELETE FROM history WHERE id = ?") { bind($0, 1, id.uuidString) }
    }

    func clearHistory() {
        exec("DELETE FROM history;")
        exec("DELETE FROM history_fts;")
    }

    func bookmarks() -> [Bookmark] {
        queryBookmarks("SELECT id, url, title, host, created FROM bookmark ORDER BY created DESC", match: nil, limit: nil)
    }

    func searchBookmarks(_ raw: String, limit: Int) -> [Bookmark] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(bookmarks().prefix(limit)) }
        if let match = LibrarySearch.ftsQuery(trimmed) {
            let sql = """
            SELECT b.id, b.url, b.title, b.host, b.created
            FROM bookmark_fts
            JOIN bookmark b ON b.url = bookmark_fts.url
            WHERE bookmark_fts MATCH ?
            ORDER BY b.created DESC
            LIMIT ?
            """
            let found = queryBookmarks(sql, match: match, limit: limit)
            if !found.isEmpty { return found }
        }
        return bookmarks().filter { mark in
            LibrarySearch.matches(mark.title, mark.host, mark.url, query: trimmed)
        }.prefix(limit).map { $0 }
    }

    func containsBookmark(url: URL) -> Bool {
        guard let absolute = HistoryStore.normalize(url)?.absoluteString else { return false }
        var found = false
        run("SELECT 1 FROM bookmark WHERE url = ? LIMIT 1", step: true) { stmt in
            bind(stmt, 1, absolute)
        } read: { stmt in
            if sqlite3_column_int(stmt, 0) == 1 { found = true }
        }
        return found
    }

    @discardableResult
    func toggleBookmark(url: URL, title: String) -> Bool {
        guard let normalized = HistoryStore.normalize(url), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let absolute = normalized.absoluteString
        if let existing = bookmarkRow(url: absolute) {
            deleteFTS(table: "bookmark_fts", rowid: existing.ftsRow)
            run("DELETE FROM bookmark WHERE url = ?") { bind($0, 1, absolute) }
            return false
        }
        let trimmed = String((title.isEmpty ? host : title).prefix(180))
        let fts = replaceFTS(table: "bookmark_fts", rowid: nil, title: trimmed, host: host, url: absolute)
        run("INSERT INTO bookmark (id, url, title, host, created, fts_rowid) VALUES (?, ?, ?, ?, ?, ?)") { stmt in
            bind(stmt, 1, UUID().uuidString)
            bind(stmt, 2, absolute)
            bind(stmt, 3, trimmed)
            bind(stmt, 4, host)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 6, fts)
        }
        return true
    }

    func deleteBookmark(_ id: UUID) {
        if let row = bookmarkRow(id: id.uuidString) {
            deleteFTS(table: "bookmark_fts", rowid: row.ftsRow)
        }
        run("DELETE FROM bookmark WHERE id = ?") { bind($0, 1, id.uuidString) }
    }

    func zoom(for host: String) -> Double? {
        let key = host.lowercased()
        var value: Double?
        run("SELECT factor FROM zoom WHERE host = ? LIMIT 1", step: true) { stmt in
            bind(stmt, 1, key)
        } read: { stmt in
            value = sqlite3_column_double(stmt, 0)
        }
        return value
    }

    func setZoom(_ host: String, _ factor: Double) {
        let key = host.lowercased()
        run("INSERT INTO zoom (host, factor) VALUES (?, ?) ON CONFLICT(host) DO UPDATE SET factor = excluded.factor") { stmt in
            bind(stmt, 1, key)
            sqlite3_bind_double(stmt, 2, factor)
        }
    }

    func clearZoom(_ host: String) {
        run("DELETE FROM zoom WHERE host = ?") { bind($0, 1, host.lowercased()) }
    }

    private struct StoredHistory {
        var visitCount: Int
        var ftsRow: Int64
    }

    private struct StoredBookmark {
        var ftsRow: Int64
    }

    private func historyRow(url: String) -> StoredHistory? {
        var row: StoredHistory?
        run("SELECT visit_count, fts_rowid FROM history WHERE url = ? LIMIT 1", step: true) { stmt in
            bind(stmt, 1, url)
        } read: { stmt in
            row = StoredHistory(visitCount: Int(sqlite3_column_int(stmt, 0)), ftsRow: sqlite3_column_int64(stmt, 1))
        }
        return row
    }

    private func historyRow(id: String) -> StoredHistory? {
        var row: StoredHistory?
        run("SELECT visit_count, fts_rowid FROM history WHERE id = ? LIMIT 1", step: true) { stmt in
            bind(stmt, 1, id)
        } read: { stmt in
            row = StoredHistory(visitCount: Int(sqlite3_column_int(stmt, 0)), ftsRow: sqlite3_column_int64(stmt, 1))
        }
        return row
    }

    private func bookmarkRow(url: String) -> StoredBookmark? {
        var row: StoredBookmark?
        run("SELECT fts_rowid FROM bookmark WHERE url = ? LIMIT 1", step: true) { stmt in
            bind(stmt, 1, url)
        } read: { stmt in
            row = StoredBookmark(ftsRow: sqlite3_column_int64(stmt, 0))
        }
        return row
    }

    private func bookmarkRow(id: String) -> StoredBookmark? {
        var row: StoredBookmark?
        run("SELECT fts_rowid FROM bookmark WHERE id = ? LIMIT 1", step: true) { stmt in
            bind(stmt, 1, id)
        } read: { stmt in
            row = StoredBookmark(ftsRow: sqlite3_column_int64(stmt, 0))
        }
        return row
    }

    private func queryHistory(_ sql: String, match: String? = nil, limit: Int) -> [HistoryEntry] {
        var rows: [HistoryEntry] = []
        run(sql, step: true) { stmt in
            var index: Int32 = 1
            if let match { bind(stmt, index, match); index += 1 }
            sqlite3_bind_int(stmt, index, Int32(limit))
        } read: { stmt in
            if let entry = historyEntry(stmt) { rows.append(entry) }
        }
        return rows
    }

    private func likeHistory(_ raw: String, limit: Int) -> [HistoryEntry] {
        let pattern = LibrarySearch.likePattern(raw)
        let sql = """
        SELECT id, url, title, host, visit_count, last_visit FROM history
        WHERE title LIKE ? ESCAPE '\\' OR host LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\'
        ORDER BY last_visit DESC LIMIT ?
        """
        var rows: [HistoryEntry] = []
        run(sql, step: true) { stmt in
            bind(stmt, 1, pattern)
            bind(stmt, 2, pattern)
            bind(stmt, 3, pattern)
            sqlite3_bind_int(stmt, 4, Int32(limit))
        } read: { stmt in
            if let entry = historyEntry(stmt) { rows.append(entry) }
        }
        return rows
    }

    private func historyEntry(_ stmt: OpaquePointer?) -> HistoryEntry? {
        guard let id = columnText(stmt, 0), let uuid = UUID(uuidString: id),
              let url = columnText(stmt, 1),
              let title = columnText(stmt, 2),
              let host = columnText(stmt, 3) else { return nil }
        return HistoryEntry(
            id: uuid,
            url: url,
            title: title,
            host: host,
            visitCount: Int(sqlite3_column_int(stmt, 4)),
            lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        )
    }

    private func queryBookmarks(_ sql: String, match: String?, limit: Int?) -> [Bookmark] {
        var rows: [Bookmark] = []
        run(sql, step: true) { stmt in
            var index: Int32 = 1
            if let match { bind(stmt, index, match); index += 1 }
            if let limit { sqlite3_bind_int(stmt, index, Int32(limit)) }
        } read: { stmt in
            guard let id = columnText(stmt, 0), let uuid = UUID(uuidString: id),
                  let url = columnText(stmt, 1),
                  let title = columnText(stmt, 2),
                  let host = columnText(stmt, 3) else { return }
            rows.append(Bookmark(
                id: uuid,
                url: url,
                title: title,
                host: host,
                created: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            ))
        }
        return rows
    }

    private func evictHistory() {
        let extra = count("SELECT COUNT(*) FROM history") - Self.historyCap
        guard extra > 0 else { return }
        var victims: [(String, Int64)] = []
        run("SELECT id, fts_rowid FROM history ORDER BY last_visit ASC LIMIT ?", step: true) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(extra))
        } read: { stmt in
            if let id = columnText(stmt, 0) {
                victims.append((id, sqlite3_column_int64(stmt, 1)))
            }
        }
        for victim in victims {
            deleteFTS(table: "history_fts", rowid: victim.1)
            run("DELETE FROM history WHERE id = ?") { bind($0, 1, victim.0) }
        }
    }

    private func replaceFTS(table: String, rowid: Int64?, title: String, host: String, url: String) -> Int64 {
        if let rowid { deleteFTS(table: table, rowid: rowid) }
        run("INSERT INTO \(table) (title, host, url) VALUES (?, ?, ?)") { stmt in
            bind(stmt, 1, title)
            bind(stmt, 2, host)
            bind(stmt, 3, url)
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func deleteFTS(table: String, rowid: Int64) {
        guard rowid > 0 else { return }
        run("INSERT INTO \(table)(\(table), rowid) VALUES('delete', ?)") { stmt in
            sqlite3_bind_int64(stmt, 1, rowid)
        }
    }

    private func importJSONIfNeeded() {
        guard meta("imported") != "1" else { return }
        if count("SELECT COUNT(*) FROM history") == 0, let entries = JSONStore.load("history.json", as: [HistoryEntry].self) {
            for entry in entries {
                guard let url = URL(string: entry.url) else { continue }
                recordHistory(url: url, title: entry.title)
                if entry.visitCount > 1 {
                    run("UPDATE history SET visit_count = ?, last_visit = ? WHERE url = ?") { stmt in
                        sqlite3_bind_int(stmt, 1, Int32(entry.visitCount))
                        sqlite3_bind_double(stmt, 2, entry.lastVisit.timeIntervalSince1970)
                        bind(stmt, 3, entry.url)
                    }
                }
            }
        }
        if count("SELECT COUNT(*) FROM bookmark") == 0, let marks = JSONStore.load("bookmarks.json", as: [Bookmark].self) {
            for mark in marks.reversed() {
                guard let url = URL(string: mark.url) else { continue }
                _ = toggleBookmark(url: url, title: mark.title)
                run("UPDATE bookmark SET created = ? WHERE url = ?") { stmt in
                    sqlite3_bind_double(stmt, 1, mark.created.timeIntervalSince1970)
                    bind(stmt, 2, mark.url)
                }
            }
        }
        setMeta("imported", "1")
        renameImported("history.json")
        renameImported("bookmarks.json")
    }

    private func renameImported(_ name: String) {
        guard let file = try? JSONStore.url(name), FileManager.default.fileExists(atPath: file.path) else { return }
        let dest = file.appendingPathExtension("imported")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: file, to: dest)
    }

    private func count(_ sql: String) -> Int {
        var value = 0
        run(sql, step: true) { _ in } read: { stmt in
            value = Int(sqlite3_column_int(stmt, 0))
        }
        return value
    }

    private func meta(_ key: String) -> String? {
        var value: String?
        run("SELECT value FROM meta WHERE key = ? LIMIT 1", step: true) { bind($0, 1, key) } read: { stmt in
            value = columnText(stmt, 0)
        }
        return value
    }

    private func setMeta(_ key: String, _ value: String) {
        run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value") { stmt in
            bind(stmt, 1, key)
            bind(stmt, 2, value)
        }
    }

    private func exec(_ sql: String) {
        guard db != nil else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func run(_ sql: String, step: Bool, bind bindBlock: (OpaquePointer?) -> Void, read: ((OpaquePointer?) -> Void)? = nil) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindBlock(stmt)
        if !step {
            sqlite3_step(stmt)
            return
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            read?(stmt)
        }
    }

    private func run(_ sql: String, bind bindBlock: (OpaquePointer?) -> Void) {
        run(sql, step: false, bind: bindBlock, read: nil)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }
}

enum LibrarySearch {
    static func ftsQuery(_ raw: String) -> String? {
        let tokens = raw.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    static func likePattern(_ raw: String) -> String {
        let escaped = raw.lowercased()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    static func matches(_ title: String, _ host: String, _ url: String, query: String) -> Bool {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return true }
        return title.lowercased().contains(needle) || host.lowercased().contains(needle) || url.lowercased().contains(needle)
    }
}

enum SiteZoom {
    static let minimum = 0.5
    static let maximum = 3.0
    static let step = 0.1

    static func clamp(_ value: Double) -> Double {
        let rounded = (value * 100).rounded() / 100
        return min(maximum, max(minimum, rounded))
    }

    /// `delta` 0 resets to 100%. Positive zooms in.
    static func adjust(_ current: Double, delta: Int) -> Double {
        if delta == 0 { return 1 }
        return clamp(current + (Double(delta) * step))
    }
}

enum FindIndex {
    static func step(_ index: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return -1 }
        let start = index < 0 ? (forward ? -1 : 0) : index
        if forward { return (start + 1) % count }
        return (start - 1 + count) % count
    }
}
