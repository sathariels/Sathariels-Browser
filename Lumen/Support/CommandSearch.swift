import Foundation

struct CommandHit: Equatable, Identifiable {
    enum Kind: Equatable { case tab, bookmark, history }
    var id: String
    var title: String
    var subtitle: String
    var kind: Kind
    var url: String?
    var tabID: UUID?
}

enum CommandSearch {
    static func results(
        query: String,
        tabs: [(UUID, String, String)],
        bookmarks: [Bookmark],
        history: [HistoryEntry],
        limit: Int = 12
    ) -> [CommandHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hits: [CommandHit] = []
        for tab in tabs where needle.isEmpty || tab.1.lowercased().contains(needle) || tab.2.lowercased().contains(needle) {
            hits.append(CommandHit(
                id: "tab-\(tab.0.uuidString)",
                title: tab.1.isEmpty ? "New Tab" : tab.1,
                subtitle: tab.2.isEmpty ? "Open tab" : tab.2,
                kind: .tab,
                url: tab.2.isEmpty ? nil : tab.2,
                tabID: tab.0
            ))
        }
        for mark in bookmarks where needle.isEmpty || LibrarySearch.matches(mark.title, mark.host, mark.url, query: needle) {
            hits.append(CommandHit(
                id: "bookmark-\(mark.id.uuidString)",
                title: mark.title,
                subtitle: mark.host,
                kind: .bookmark,
                url: mark.url,
                tabID: nil
            ))
        }
        for entry in history where needle.isEmpty || LibrarySearch.matches(entry.title, entry.host, entry.url, query: needle) {
            hits.append(CommandHit(
                id: "history-\(entry.id.uuidString)",
                title: entry.title,
                subtitle: entry.host,
                kind: .history,
                url: entry.url,
                tabID: nil
            ))
        }
        return Array(hits.prefix(limit))
    }
}
