import Foundation

/// Frecency-ranked address suggestions. The index is a flat array of short strings.
enum Omnibox {
    enum Kind: String, Codable {
        case history
        case bookmark
        case tab
        case search
    }

    struct Entry: Equatable {
        var urlString: String
        var host: String
        var title: String
        var frecency: Double
        var kind: Kind
        var tabID: UUID?
    }

    struct Candidate: Identifiable, Equatable {
        var id: String
        var title: String
        var subtitle: String
        var urlString: String?
        var kind: Kind
        var tabID: UUID?
        var query: String?
    }

    static func frecency(visitCount: Int, lastVisit: Date, now: Date = Date()) -> Double {
        let days = now.timeIntervalSince(lastVisit) / 86_400
        let weight: Double
        switch days {
        case ..<1: weight = 1
        case ..<7: weight = 0.7
        case ..<30: weight = 0.45
        default: weight = 0.2
        }
        return Double(max(visitCount, 1)) * weight
    }

    /// Host completion for a typed prefix. Nil when there is nothing to add.
    /// Requires two characters so a single letter does not rewrite the field.
    static func inlineHost(prefix: String, entries: [Entry]) -> String? {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.count >= 2 else { return nil }
        if typed.contains(" ") || typed.contains("/") || typed.contains(":") { return nil }
        let needle = typed.lowercased()
        let matches = entries.filter { $0.host.lowercased().hasPrefix(needle) && $0.host.count > typed.count }
        guard let best = matches.max(by: { $0.frecency < $1.frecency }) else { return nil }
        return best.host
    }

    /// Suffix that should be selected after `typed`, preserving the user's casing.
    static func completionSuffix(typed: String, suggestion: String) -> String? {
        guard suggestion.count > typed.count else { return nil }
        let head = suggestion.prefix(typed.count)
        guard head.lowercased() == typed.lowercased() else { return nil }
        return String(suggestion.dropFirst(typed.count))
    }

    static func suggestions(
        prefix: String,
        entries: [Entry],
        engine: SearchEngine,
        limit: Int = 8
    ) -> [Candidate] {
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        let needle = typed.lowercased()
        var ranked: [(Double, Entry)] = []
        ranked.reserveCapacity(min(entries.count, 32))
        for entry in entries {
            let score = rank(entry, needle: needle)
            if score >= 0 {
                ranked.append((score, entry))
            }
        }
        ranked.sort { $0.0 > $1.0 }
        var seen = Set<String>()
        var rows: [Candidate] = []
        for (_, entry) in ranked {
            let key = entry.tabID?.uuidString ?? entry.urlString
            if seen.contains(key) { continue }
            seen.insert(key)
            rows.append(Candidate(
                id: key,
                title: entry.title.isEmpty ? entry.host : entry.title,
                subtitle: entry.host,
                urlString: entry.urlString,
                kind: entry.kind,
                tabID: entry.tabID,
                query: nil
            ))
            if rows.count >= limit { break }
        }
        rows.append(Candidate(
            id: "search:\(typed)",
            title: "Search \(engine.label) for \(typed)",
            subtitle: engine.label,
            urlString: engine.searchURL(for: typed)?.absoluteString,
            kind: .search,
            tabID: nil,
            query: typed
        ))
        return rows
    }

    private static func rank(_ entry: Entry, needle: String) -> Double {
        let host = entry.host.lowercased()
        let title = entry.title.lowercased()
        let url = entry.urlString.lowercased()
        let score: Double
        if host.hasPrefix(needle) {
            score = 1_000
        } else if host.contains(needle) {
            score = 120
        } else if title.contains(needle) {
            score = 40
        } else if url.contains(needle) {
            score = 15
        } else {
            return -1
        }
        return score + entry.frecency
    }
}
