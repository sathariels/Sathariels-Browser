import Foundation

enum PageWarning: Equatable {
    case httpsFailed(URL)
    case unsafe(URL)
}

enum TrackingStrip {
    private static let names: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid",
        "mc_eid", "mc_cid", "igshid", "igsh", "twclid", "ttclid", "yclid",
        "srsltid", "_hsenc", "_hsmi", "mkt_tok", "vero_id", "oly_enc_id",
        "oly_anon_id", "_ga", "_gl", "s_cid", "wickedid", "li_fat_id",
        "fb_action_ids", "fb_action_types", "fb_source", "fb_ref",
    ]

    static func isTracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utm_") || names.contains(lower)
    }

    /// Returns a cleaned URL when at least one tracking parameter was removed.
    static func stripped(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return nil }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url
    }
}

enum HTTPSOnly {
    static func isExempt(host: String?) -> Bool {
        let value = host?.lowercased() ?? ""
        return value == "localhost" || value == "127.0.0.1"
    }

    static func upgraded(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", !isExempt(host: url.host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }
}
