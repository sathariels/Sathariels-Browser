import Foundation

/// Converts a conservative subset of Adblock Plus filters into WebKit content rules.
/// Network rules are `||host^` and simple path anchors. Cosmetic rules are plain class and id selectors.
enum FilterListCompiler {
    static let chunkLimit = 8_000
    private static let resourceTypes = [
        "script": "script",
        "image": "image",
        "stylesheet": "style-sheet",
        "font": "font",
        "media": "media",
        "xmlhttprequest": "raw",
        "other": "raw",
        "subdocument": "document",
        "document": "document",
        "popup": "popup",
        "svg": "svg-document",
    ]
    private static let allowedOptions: Set<String> = [
        "script", "image", "stylesheet", "font", "media", "xmlhttprequest", "other",
        "subdocument", "document", "popup", "svg", "third-party", "first-party",
        "match-case", "important", "domain",
    ]

    static let accountException: [String: Any] = [
        "trigger": [
            "url-filter": "^https?://",
            "if-domain": ["*accounts.google.com", "*myaccount.google.com", "*accounts.youtube.com"],
        ],
        "action": ["type": "ignore-previous-rules"],
    ]

    static func rules(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("!"), !trimmed.hasPrefix("["), !trimmed.hasPrefix("# ") else { return nil }
        if trimmed.contains("##") || trimmed.contains("#@#") || trimmed.contains("#?#") {
            return cosmetic(trimmed)
        }
        return network(trimmed)
    }

    static func writeChunks(from sources: [URL], to directory: URL) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix("blocker-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        for source in sources {
            guard let text = try? String(contentsOf: source, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                guard let rule = rules(from: String(line)) else { continue }
                if (rule["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" {
                    exceptions.append(rule)
                } else {
                    blocks.append(rule)
                }
            }
        }
        var index = 0
        var batch: [[String: Any]] = []
        func flush() throws {
            guard !batch.isEmpty || !exceptions.isEmpty else { return }
            let payload = batch + exceptions + [accountException]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let url = directory.appendingPathComponent("blocker-\(index).json")
            try data.write(to: url, options: .atomic)
            index += 1
            batch = []
        }
        for rule in blocks {
            batch.append(rule)
            if batch.count + exceptions.count + 1 >= chunkLimit {
                try flush()
            }
        }
        if !batch.isEmpty || !exceptions.isEmpty {
            try flush()
        }
        return blocks.count
    }

    private static func network(_ line: String) -> [String: Any]? {
        let exception = line.hasPrefix("@@")
        let body = exception ? String(line.dropFirst(2)) : line
        let parts = body.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        let pattern = String(parts[0]).trimmingCharacters(in: .whitespaces)
        var trigger: [String: Any] = [:]
        if parts.count == 2 {
            guard let extra = options(String(parts[1])) else { return nil }
            trigger = extra
        }
        guard let regex = urlFilter(pattern), regex.count <= 500 else { return nil }
        var full = trigger
        full["url-filter"] = regex
        if full["url-filter-is-case-sensitive"] == nil {
            full["url-filter-is-case-sensitive"] = false
        }
        let action = exception ? "ignore-previous-rules" : "block"
        return ["trigger": full, "action": ["type": action]]
    }

    private static func cosmetic(_ line: String) -> [String: Any]? {
        if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") { return nil }
        guard let range = line.range(of: "##") else { return nil }
        let domains = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard selectorOK(selector) else { return nil }
        var trigger: [String: Any] = ["url-filter": ".*"]
        if !domains.isEmpty {
            if domains.hasPrefix("~") { return nil }
            var include: [String] = []
            for domain in domains.split(separator: ",") {
                let host = domain.trimmingCharacters(in: .whitespaces).lowercased()
                if host.isEmpty || host.hasPrefix("~") || !hostOK(host) { return nil }
                include.append("*" + host)
            }
            guard !include.isEmpty else { return nil }
            trigger["if-domain"] = include
        }
        return ["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]]
    }

    private static func options(_ raw: String) -> [String: Any]? {
        var trigger: [String: Any] = [:]
        var types: [String] = []
        for part in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            if part.hasPrefix("domain=") {
                var include: [String] = []
                var exclude: [String] = []
                for item in part.dropFirst(7).split(separator: "|") {
                    let token = String(item)
                    let negated = token.hasPrefix("~")
                    let host = (negated ? String(token.dropFirst()) : token).lowercased()
                    guard hostOK(host) else { return nil }
                    if negated {
                        exclude.append("*" + host)
                    } else {
                        include.append("*" + host)
                    }
                }
                if !include.isEmpty { trigger["if-domain"] = include }
                if !exclude.isEmpty { trigger["unless-domain"] = exclude }
                continue
            }
            let name = part.hasPrefix("~") ? String(part.dropFirst()) : part
            guard allowedOptions.contains(name) || part.hasPrefix("~") else { return nil }
            if part.hasPrefix("~") {
                guard part == "~third-party" else { return nil }
                trigger["load-type"] = ["first-party"]
                continue
            }
            switch part {
            case "third-party":
                trigger["load-type"] = ["third-party"]
            case "first-party":
                trigger["load-type"] = ["first-party"]
            case "match-case":
                trigger["url-filter-is-case-sensitive"] = true
            case "important":
                break
            default:
                if let mapped = resourceTypes[part] {
                    types.append(mapped)
                } else {
                    return nil
                }
            }
        }
        if !types.isEmpty { trigger["resource-type"] = types }
        return trigger
    }

    static func urlFilter(_ pattern: String) -> String? {
        var text = pattern
        var anchored = false
        if text.hasPrefix("||") {
            anchored = true
            text = String(text.dropFirst(2))
        } else if text.hasPrefix("|") {
            text = String(text.dropFirst())
        }
        if text.hasSuffix("|") { text = String(text.dropLast()) }
        while text.hasSuffix("^") { text = String(text.dropLast()) }
        guard !text.isEmpty, !text.contains("*"), !text.hasPrefix("/") else { return nil }
        let hostPart: String
        let path: String
        if let slash = text.firstIndex(of: "/") {
            hostPart = String(text[..<slash]).lowercased()
            path = String(text[text.index(after: slash)...])
        } else {
            hostPart = text.lowercased()
            path = ""
        }
        guard hostOK(hostPart) else { return nil }
        let escapedHost = escapeRegex(hostPart)
        if anchored && path.isEmpty {
            return "^https?://([^/?#]*\\.)?\(escapedHost)[:/?#]"
        }
        if anchored && !path.isEmpty {
            return "^https?://([^/?#]*\\.)?\(escapedHost)/\(escapeRegex(path))"
        }
        if !path.isEmpty { return nil }
        let escaped = escapeRegex(text)
        guard escaped.count >= 4 else { return nil }
        return escaped
    }

    private static func selectorOK(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count <= 180 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_#.- ,")
        return selector.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func hostOK(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func escapeRegex(_ text: String) -> String {
        var out = ""
        for ch in text {
            if ".\\+?^${}()|[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
