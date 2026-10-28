import Foundation

enum GoogleSignInDetector {
    static func isAccountsHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "accounts.google.com"
            || host == "accounts.youtube.com"
            || host.hasSuffix(".accounts.google.com")
    }

    static func isRejection(url: URL) -> Bool {
        guard isAccountsHost(url.host) else { return false }
        let path = url.path.lowercased()
        if path.contains("rejected") || path.contains("disabled") { return true }
        let query = url.query?.lowercased() ?? ""
        if query.contains("disallowed_useragent") || query.contains("unsupported_browser") {
            return true
        }
        return false
    }

    static func isRejection(url: URL, pageText: String) -> Bool {
        if isRejection(url: url) { return true }
        guard isAccountsHost(url.host) else { return false }
        let text = pageText.lowercased()
        if text.contains("may not be secure") { return true }
        if text.contains("couldn't sign you in") || text.contains("couldn’t sign you in") { return true }
        if text.contains("browser or app may not be secure") { return true }
        return false
    }
}
