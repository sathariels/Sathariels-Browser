import Foundation

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let cap = LibraryDB.historyCap

    @Published private(set) var entries: [HistoryEntry] = []
    private(set) var omniboxEntries: [Omnibox.Entry] = []

    private init() {
        reload()
    }

    func record(url: URL, title: String) {
        LibraryDB.shared.recordHistory(url: url, title: title)
        reload()
    }

    func clear() {
        LibraryDB.shared.clearHistory()
        reload()
    }

    func delete(_ id: UUID) {
        LibraryDB.shared.deleteHistory(id)
        reload()
    }

    func search(_ query: String, limit: Int = 50) -> [HistoryEntry] {
        LibraryDB.shared.searchHistory(query, limit: limit)
    }

    private func reload() {
        entries = LibraryDB.shared.recentHistory(limit: 200)
        omniboxEntries = LibraryDB.shared.recentHistory(limit: 400).map { entry in
            Omnibox.Entry(
                urlString: entry.url,
                host: entry.host,
                title: String(entry.title.prefix(80)),
                frecency: Omnibox.frecency(visitCount: entry.visitCount, lastVisit: entry.lastVisit),
                kind: .history,
                tabID: nil
            )
        }
    }

    static func normalize(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = nil
        if parts.scheme == "http" || parts.scheme == "https" {
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
        }
        return parts.url
    }
}
