import Foundation

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case duckDuckGo
    case google
    case bing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let template: String
        switch self {
        case .duckDuckGo: template = "https://duckduckgo.com/?q=\(encoded)"
        case .google: template = "https://www.google.com/search?q=\(encoded)"
        case .bing: template = "https://www.bing.com/search?q=\(encoded)"
        }
        return URL(string: template)
    }
}

enum AddressResolver {
    /// Turns the address bar into a URL. Words become a search. Hosts get https.
    static func resolve(_ raw: String, engine: SearchEngine, shortcuts: [KeywordShortcut] = []) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let keyword = KeywordRouter.resolve(text, custom: shortcuts) {
            return keyword
        }

        if text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("file://") {
            return URL(string: text)
        }
        if text.hasPrefix("about:") {
            return URL(string: text)
        }

        let hasSpace = text.contains(" ") || text.contains("\t")
        if hasSpace {
            return engine.searchURL(for: text)
        }

        if looksLikeHost(text) {
            return URL(string: "https://\(text)")
        }
        return engine.searchURL(for: text)
    }

    static func looksLikeHost(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("localhost") { return true }
        if lower.contains(":") && !lower.contains(" ") {
            // host:port
            let host = lower.split(separator: ":").first.map(String.init) ?? lower
            if host == "localhost" || isIP(host) { return true }
        }
        if isIP(lower) { return true }
        // A dotted host with a letter or number on each side, no spaces.
        guard lower.contains(".") else { return false }
        let host = lower.split(separator: "/").first.map(String.init) ?? lower
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func isIP(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0) != nil }
    }
}
