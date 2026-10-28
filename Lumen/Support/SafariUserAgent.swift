import Foundation

enum SafariUserAgent {
    /// Used when Safari.app cannot be read (sandbox or a missing install).
    static let fallbackVersion = "26.1"

    static var current: String {
        let version = installedSafariVersion() ?? fallbackVersion
        // Safari's frozen macOS token. No app name: Google treats extra tokens as a webview.
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }

    static func installedSafariVersion() -> String? {
        let url = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let short = plist["CFBundleShortVersionString"] as? String,
              short.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
        else { return nil }
        return short
    }
}
