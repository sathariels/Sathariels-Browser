import Foundation

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case googleAI
    case duckDuckGo
    case google
    case bing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .googleAI: return "Google AI Mode"
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .googleAI, .google: base = "https://www.google.com/search"
        case .bing: base = "https://www.bing.com/search"
        }
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        if self == .googleAI { components.queryItems?.append(URLQueryItem(name: "udm", value: "50")) }
        // '+' is interpreted as a space by form-style search endpoints.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
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
            let host = URLComponents(string: "http://\(text)")?.host?.lowercased() ?? ""
            let local = host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "[::1]"
            return URL(string: "\(local ? "http" : "https")://\(text)")
        }
        return engine.searchURL(for: text)
    }

    static func looksLikeHost(_ text: String) -> Bool {
        guard let components = URLComponents(string: "https://\(text)"),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "[::1]" { return true }
        if isIP(host) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { part in
            !part.isEmpty && part.first != "-" && part.last != "-" &&
            part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func isIP(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}
