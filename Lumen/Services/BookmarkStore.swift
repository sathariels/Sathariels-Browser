import Foundation

final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    @Published private(set) var bookmarks: [Bookmark] = []

    private init() {
        reload()
    }

    func contains(url: URL) -> Bool {
        LibraryDB.shared.containsBookmark(url: url)
    }

    func toggle(url: URL, title: String) {
        _ = LibraryDB.shared.toggleBookmark(url: url, title: title)
        reload()
    }

    func delete(_ id: UUID) {
        LibraryDB.shared.deleteBookmark(id)
        reload()
    }

    func search(_ query: String, limit: Int = 50) -> [Bookmark] {
        LibraryDB.shared.searchBookmarks(query, limit: limit)
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

    private func reload() {
        bookmarks = LibraryDB.shared.bookmarks()
    }
}
