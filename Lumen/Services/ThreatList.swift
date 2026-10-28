import CryptoKit
import Foundation

/// Local phishing and malware hashes. The browser downloads host and URL lists and never sends the address bar URL anywhere.
final class ThreatList {
    static let shared = ThreatList()
    private let hostsURL = URL(string: "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts.txt")!
    private let phishURL = URL(string: "https://raw.githubusercontent.com/openphish/public_feed/refs/heads/main/feed.txt")!
    private let fileName = "threat-hashes.bin"
    private let cap = 100_000
    private var hashes: [UInt64] = []
    private var started = false
    private let queue = DispatchQueue(label: "com.sathariels.browser.threats", qos: .utility)

    private init() {}

    func prepare() {
        guard !started else { return }
        started = true
        queue.async { [weak self] in
            self?.loadBundledOrCached()
            self?.refreshIfDue()
        }
    }

    func contains(_ url: URL) -> Bool {
        guard SettingsStore.shared.safeBrowsing else { return false }
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else { return false }
        if search(Self.hash64(host)) { return true }
        if let normalized = Self.normalize(url), search(Self.hash64(normalized)) { return true }
        return false
    }

    private func search(_ value: UInt64) -> Bool {
        hashes.withUnsafeBufferPointer { $0.binarySearch(value) }
    }

    private func loadBundledOrCached() {
        let cached = cacheURL()
        let source = (cached.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            ?? Bundle.main.url(forResource: "threat-hashes", withExtension: "bin")
        guard let source, let data = try? Data(contentsOf: source) else { return }
        let loaded = Self.decode(data)
        DispatchQueue.main.async { [weak self] in
            self?.hashes = loaded
        }
    }

    private func refreshIfDue() {
        let last = UserDefaults.standard.object(forKey: "threatListRefresh") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        let group = DispatchGroup()
        var hostText = ""
        var phishText = ""
        group.enter()
        fetch(hostsURL) { text in
            hostText = text ?? ""
            group.leave()
        }
        group.enter()
        fetch(phishURL) { text in
            phishText = text ?? ""
            group.leave()
        }
        group.wait()
        guard !hostText.isEmpty, !phishText.isEmpty else { return }
        var values = Set<UInt64>()
        for line in hostText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let host = trimmed.split(whereSeparator: \.isWhitespace).last.map(String.init)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""
            guard !host.isEmpty, host != "0.0.0.0", values.count < cap else { continue }
            values.insert(Self.hash64(host))
        }
        hostText = ""
        for line in phishText.split(whereSeparator: \.isNewline) {
            guard values.count < cap else { break }
            let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), let host = url.host?.lowercased() else { continue }
            values.insert(Self.hash64(host.trimmingCharacters(in: CharacterSet(charactersIn: "."))))
            if let normalized = Self.normalize(url) {
                values.insert(Self.hash64(normalized))
            }
        }
        phishText = ""
        let ordered = values.sorted()
        var data = Data(capacity: ordered.count * 8)
        for value in ordered {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        if let destination = cacheURL() {
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: destination, options: .atomic)
        }
        UserDefaults.standard.set(Date(), forKey: "threatListRefresh")
        DispatchQueue.main.async { [weak self] in
            self?.hashes = ordered
        }
    }

    private func fetch(_ url: URL, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data, data.count < 8_000_000,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }
            completion(text)
        }.resume()
    }

    private func cacheURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("SatharielsBrowser", isDirectory: true).appendingPathComponent(fileName)
    }

    static func hash64(_ value: String) -> UInt64 {
        let digest = SHA256.hash(data: Data(value.utf8))
        var number: UInt64 = 0
        for byte in digest.prefix(8) {
            number = (number << 8) | UInt64(byte)
        }
        return number
    }

    static func normalize(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        return "\(scheme)://\(host)\(path)\(query)"
    }

    static func decode(_ data: Data) -> [UInt64] {
        let count = min(data.count / 8, 100_000)
        guard count > 0 else { return [] }
        var values: [UInt64] = []
        values.reserveCapacity(count)
        var offset = 0
        while values.count < count {
            var value: UInt64 = 0
            withUnsafeMutableBytes(of: &value) { dest in
                data.copyBytes(to: dest, from: offset..<(offset + 8))
            }
            values.append(UInt64(littleEndian: value))
            offset += 8
        }
        return values
    }
}

private extension UnsafeBufferPointer where Element == UInt64 {
    func binarySearch(_ value: UInt64) -> Bool {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            let item = self[mid]
            if item == value { return true }
            if item < value { low = mid + 1 } else { high = mid }
        }
        return false
    }
}
