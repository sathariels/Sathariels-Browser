import Foundation

enum JSONSniffer {
    static let byteCap = 1_200_000

    static func shouldIntercept(mime: String, url: URL?) -> Bool {
        let type = mime.lowercased()
        if type.contains("json") { return true }
        return url?.pathExtension.lowercased() == "json"
    }

    static func shouldSniff(mime: String, url: URL?) -> Bool {
        if shouldIntercept(mime: mime, url: url) { return false }
        let type = mime.lowercased()
        if type.isEmpty || type.hasPrefix("text/plain") || type == "application/octet-stream" {
            return true
        }
        return false
    }

    static func looksLikeJSON(_ sample: String) -> Bool {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        return first == "{" || first == "["
    }
}

enum JSONValue {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func parse(_ data: Data) -> JSONValue? {
        guard data.count <= JSONSniffer.byteCap,
              let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return wrap(raw)
    }

    static func parse(text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parse(data)
    }

    private static func wrap(_ raw: Any) -> JSONValue {
        switch raw {
        case let dict as [String: Any]:
            let pairs = dict.keys.sorted().map { ($0, wrap(dict[$0] as Any)) }
            return .object(pairs)
        case let list as [Any]:
            return .array(list.map(wrap))
        case let text as String:
            return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.stringValue)
        default:
            return .null
        }
    }

    func path(_ suffix: String) -> String {
        suffix.isEmpty ? "$" : suffix
    }

    static func childPath(parent: String, key: String) -> String {
        if key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil {
            return parent == "$" ? "$." + key : parent + "." + key
        }
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return parent + "[\"\(escaped)\"]"
    }

    static func indexPath(parent: String, index: Int) -> String {
        parent + "[\(index)]"
    }

    var copyText: String {
        switch self {
        case .string(let text): return text
        case .number(let text): return text
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .object, .array:
            guard let data = try? JSONSerialization.data(withJSONObject: foundationValue(), options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    private func foundationValue() -> Any {
        switch self {
        case .object(let pairs):
            var dict: [String: Any] = [:]
            for pair in pairs { dict[pair.key] = pair.value.foundationValue() }
            return dict
        case .array(let items):
            return items.map { $0.foundationValue() }
        case .string(let text): return text
        case .number(let text): return NSDecimalNumber(string: text)
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}

final class JSONDocument {
    let raw: String
    let value: JSONValue

    init?(raw: String) {
        let clipped = raw.count > JSONSniffer.byteCap ? String(raw.prefix(JSONSniffer.byteCap)) : raw
        guard let value = JSONValue.parse(text: clipped) else { return nil }
        self.raw = clipped
        self.value = value
    }
}
