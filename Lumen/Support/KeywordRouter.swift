import Foundation

struct KeywordShortcut: Codable, Identifiable, Equatable {
    var id: UUID
    var keyword: String
    var template: String
}

enum KeywordRouter {
    /// Built-in keywords run when the user has not overridden that word.
    /// A custom template uses `{query}` for the rest of the line.
    static func resolve(_ raw: String, custom: [KeywordShortcut]) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pieces = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let head = pieces.first else { return nil }
        let keyword = String(head).lowercased()
        let query = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if let override = custom.first(where: { $0.keyword.lowercased() == keyword && !$0.template.isEmpty }) {
            return apply(template: override.template, query: query)
        }
        switch keyword {
        case "gh":
            return github(query)
        case "yt":
            return youtube(query)
        case "lc":
            return leetcode(query)
        default:
            return nil
        }
    }

    private static func github(_ query: String) -> URL? {
        if query.isEmpty { return URL(string: "https://github.com") }
        if looksLikeRepo(query) {
            return URL(string: "https://github.com/\(query)")
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return URL(string: "https://github.com/search?q=\(encoded)")
    }

    private static func youtube(_ query: String) -> URL? {
        if query.isEmpty { return URL(string: "https://www.youtube.com") }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return URL(string: "https://www.youtube.com/results?search_query=\(encoded)")
    }

    private static func leetcode(_ query: String) -> URL? {
        if query.isEmpty { return URL(string: "https://leetcode.com/problemset/") }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return URL(string: "https://leetcode.com/problemset/?search=\(encoded)")
    }

    private static func looksLikeRepo(_ query: String) -> Bool {
        let parts = query.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !query.contains(" ") else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        }
    }

    private static func apply(template: String, query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        let filled = template.replacingOccurrences(of: "{query}", with: encoded)
        if filled.hasPrefix("http://") || filled.hasPrefix("https://") {
            return URL(string: filled)
        }
        return URL(string: "https://\(filled)")
    }
}
