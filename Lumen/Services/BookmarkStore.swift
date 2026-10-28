import Foundation

final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    @Published private(set) var bookmarks: [Bookmark] = []

    private init() {
        bookmarks = JSONStore.load("bookmarks.json", as: [Bookmark].self) ?? []
    }

    func contains(url: URL) -> Bool {
        guard let absolute = HistoryStore.normalize(url)?.absoluteString else { return false }
        return bookmarks.contains { $0.url == absolute }
    }

    func toggle(url: URL, title: String) {
        guard let normalized = HistoryStore.normalize(url), let host = url.host?.lowercased() else { return }
        let absolute = normalized.absoluteString
        if let index = bookmarks.firstIndex(where: { $0.url == absolute }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(Bookmark(
                id: UUID(),
                url: absolute,
                title: title.isEmpty ? host : String(title.prefix(180)),
                host: host,
                created: Date()
            ), at: 0)
        }
        JSONStore.save(bookmarks, as: "bookmarks.json")
    }

    func delete(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        JSONStore.save(bookmarks, as: "bookmarks.json")
    }

    func omniboxEntries() -> [Omnibox.Entry] {
        bookmarks.map { mark in
            Omnibox.Entry(
                urlString: mark.url,
                host: mark.host,
                title: String(mark.title.prefix(80)),
                frecency: 2.2,
                kind: .bookmark,
                tabID: nil
            )
        }
    }
}
