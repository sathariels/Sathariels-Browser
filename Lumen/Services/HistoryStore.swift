import Foundation

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let cap = 1500

    @Published private(set) var entries: [HistoryEntry] = []
    private(set) var omniboxEntries: [Omnibox.Entry] = []

    private init() {
        entries = JSONStore.load("history.json", as: [HistoryEntry].self) ?? []
        rebuildIndex()
    }

    func record(url: URL, title: String) {
        guard let normalized = Self.normalize(url), let host = url.host?.lowercased(), !host.isEmpty else { return }
        let absolute = normalized.absoluteString
        let trimmedTitle = String(title.prefix(180))
        if let index = entries.firstIndex(where: { $0.url == absolute }) {
            entries[index].visitCount += 1
            entries[index].lastVisit = Date()
            if !trimmedTitle.isEmpty { entries[index].title = trimmedTitle }
        } else {
            entries.append(HistoryEntry(
                id: UUID(),
                url: absolute,
                title: trimmedTitle.isEmpty ? host : trimmedTitle,
                host: host,
                visitCount: 1,
                lastVisit: Date()
            ))
        }
        evict()
        rebuildIndex()
        JSONStore.save(entries, as: "history.json")
    }

    func clear() {
        entries = []
        omniboxEntries = []
        JSONStore.save(entries, as: "history.json")
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        rebuildIndex()
        JSONStore.save(entries, as: "history.json")
    }

    private func evict() {
        guard entries.count > Self.cap else { return }
        entries.sort {
            Omnibox.frecency(visitCount: $0.visitCount, lastVisit: $0.lastVisit) >
            Omnibox.frecency(visitCount: $1.visitCount, lastVisit: $1.lastVisit)
        }
        entries = Array(entries.prefix(Self.cap))
    }

    private func rebuildIndex() {
        omniboxEntries = entries.map { entry in
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
