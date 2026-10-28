import AppKit
import CryptoKit
import Foundation

enum VersionCompare {
    static func parts(_ raw: String) -> [Int] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text.split(separator: ".").map { piece in
            let digits = piece.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let left = parts(remote)
        let right = parts(local)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func same(_ left: String, _ right: String) -> Bool {
        !isNewer(left, than: right) && !isNewer(right, than: left)
    }
}

enum HomebrewInstall {
    static let caskDirectories = [
        "/opt/homebrew/Caskroom/sathariels-browser",
        "/usr/local/Caskroom/sathariels-browser",
    ]
    static let brewCandidates = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    static func isCaskInstall(fileExists: (String) -> Bool) -> Bool {
        caskDirectories.contains { fileExists($0) }
    }

    static func brewExecutable(fileExists: (String) -> Bool) -> String? {
        brewCandidates.first { fileExists($0) }
    }
}

enum ReleaseChecksum {
    static let assetName = "Sathariels.Browser-macos.zip"
    static let sumsName = "SHA256SUMS"

    static func parseSums(_ text: String, asset: String = assetName) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts.last ?? ""
            let hash = parts[0].lowercased()
            guard name == asset || name.hasSuffix("/" + asset) else { continue }
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            return hash
        }
        return nil
    }

    static func parseBody(_ text: String, asset: String = assetName) -> String? {
        let needle = "SHA256 \(asset) "
        for line in text.split(whereSeparator: \.isNewline) {
            let row = String(line).trimmingCharacters(in: .whitespaces)
            guard row.hasPrefix(needle) else { continue }
            let hash = String(row.dropFirst(needle.count)).trimmingCharacters(in: .whitespaces).lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            return hash
        }
        return nil
    }

    static func sha256(file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(file: URL, expected: String) -> Bool {
        guard let actual = sha256(file: file) else { return false }
        return actual == expected.lowercased()
    }
}

enum UpdateSchedule {
    static let interval: TimeInterval = 86_400

    static func shouldQuery(last: Date?, now: Date, manual: Bool) -> Bool {
        if manual { return true }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

struct UpdateOffer: Equatable {
    var version: String
    var notes: String
    var page: URL
    var zip: URL
    var sha256: String
}

@MainActor
final class AppUpdateCenter: ObservableObject {
    static let shared = AppUpdateCenter()

    @Published private(set) var offer: UpdateOffer?
    @Published var showSheet = false
    @Published private(set) var status = ""
    @Published private(set) var log = ""
    @Published private(set) var failed = false
    @Published private(set) var busy = false

    private var scheduled = false
    private var work: DispatchWorkItem?
    private var inFlight = false
    private let defaults = UserDefaults.standard
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    var showsButton: Bool {
        guard let offer else { return false }
        return defaults.string(forKey: "appUpdateSkippedVersion") != offer.version
    }

    func scheduleAutomaticCheck() {
        guard !scheduled else { return }
        scheduled = true
        let item = DispatchWorkItem { [weak self] in
            self?.check(manual: false)
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    func check(manual: Bool) {
        if manual {
            showSheet = true
            failed = false
            status = "Checking…"
        }
        let last = defaults.object(forKey: "appUpdateLastCheck") as? Date
        guard UpdateSchedule.shouldQuery(last: last, now: Date(), manual: manual) else {
            if manual { status = offer == nil ? "Already checked today." : "Update \(offer?.version ?? "") is available." }
            return
        }
        guard !inFlight else { return }
        inFlight = true
        let etag = defaults.string(forKey: "appUpdateETag")
        Task { [weak self] in
            await self?.fetch(etag: etag, manual: manual)
        }
    }

    func later() {
        showSheet = false
        log = ""
        failed = false
    }

    func skip() {
        if let version = offer?.version {
            defaults.set(version, forKey: "appUpdateSkippedVersion")
        }
        showSheet = false
        objectWillChange.send()
    }

    func openReleasePage() {
        let url = offer?.page ?? URL(string: "https://github.com/sathariels/Sathariels-Browser/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    func install() {
        guard let offer, !busy else { return }
        busy = true
        failed = false
        log = ""
        status = "Updating to \(offer.version)…"
        Task { [weak self] in
            await self?.runInstall(offer)
        }
    }

    private func fetch(etag: String?, manual: Bool) async {
        defer { inFlight = false }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/sathariels/Sathariels-Browser/releases/latest")!)
        request.setValue("Sathariels-Browser", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"), remaining == "0" || http.statusCode == 403 || http.statusCode == 429 {
                noteChecked()
                if manual {
                    failed = true
                    status = "GitHub rate limit reached. Try again later."
                }
                return
            }
            if let next = http.value(forHTTPHeaderField: "ETag") {
                defaults.set(next, forKey: "appUpdateETag")
            }
            noteChecked()
            if http.statusCode == 304 {
                if manual { status = showsButton ? "Update \(offer?.version ?? "") is available." : "This is the latest version." }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                if manual {
                    failed = true
                    status = "Could not read the latest release."
                }
                return
            }
            guard var parsed = Self.parseRelease(data, sums: nil) else {
                if manual {
                    failed = true
                    status = "The latest release could not be read."
                }
                return
            }
            if parsed.sha256.isEmpty, let sumsURL = Self.sumsURL(in: data) {
                var sumsRequest = URLRequest(url: sumsURL)
                sumsRequest.setValue("Sathariels-Browser", forHTTPHeaderField: "User-Agent")
                if let (sumsData, sumsResponse) = try? await session.data(for: sumsRequest),
                   let httpSums = sumsResponse as? HTTPURLResponse, (200..<300).contains(httpSums.statusCode),
                   let text = String(data: sumsData, encoding: .utf8),
                   let hash = ReleaseChecksum.parseSums(text) {
                    parsed = UpdateOffer(version: parsed.version, notes: parsed.notes, page: parsed.page, zip: parsed.zip, sha256: hash)
                }
            }
            guard !parsed.sha256.isEmpty else {
                if manual {
                    failed = true
                    status = "The latest release has no checksum yet."
                }
                return
            }
            let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            if VersionCompare.isNewer(parsed.version, than: local) {
                offer = parsed
                status = "Version \(parsed.version) is available."
                if manual { showSheet = true }
            } else if manual {
                offer = nil
                status = "This is the latest version."
            }
        } catch {
            if manual {
                failed = true
                status = "Could not reach GitHub."
            }
        }
    }

    private func noteChecked() {
        defaults.set(Date(), forKey: "appUpdateLastCheck")
    }

    static func parseRelease(_ data: Data, sums: String?) -> UpdateOffer? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let version = (json["tag_name"] as? String) ?? ""
        guard !version.isEmpty else { return nil }
        let notes = String(((json["body"] as? String) ?? "").prefix(6_000))
        guard let page = URL(string: (json["html_url"] as? String) ?? "https://github.com/sathariels/Sathariels-Browser/releases/latest") else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zipURL = assets.compactMap({ item -> URL? in
            guard (item["name"] as? String) == ReleaseChecksum.assetName else { return nil }
            return URL(string: item["browser_download_url"] as? String ?? "")
        }).first else { return nil }
        let sha = ReleaseChecksum.parseBody(notes) ?? sums.flatMap { ReleaseChecksum.parseSums($0) } ?? ""
        return UpdateOffer(version: version, notes: notes, page: page, zip: zipURL, sha256: sha)
    }

    static func sumsURL(in data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        return assets.compactMap { item -> URL? in
            guard (item["name"] as? String) == ReleaseChecksum.sumsName else { return nil }
            return URL(string: item["browser_download_url"] as? String ?? "")
        }.first
    }

    private func runInstall(_ offer: UpdateOffer) async {
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        if HomebrewInstall.isCaskInstall(fileExists: exists), let brew = HomebrewInstall.brewExecutable(fileExists: exists) {
            await runBrew(brew, offer: offer)
        } else {
            await runZip(offer)
        }
    }

    private func runBrew(_ brew: String, offer: UpdateOffer) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["upgrade", "--cask", "sathariels-browser"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(text) }
        }
        do {
            try process.run()
            let exitCode = await Task.detached { () -> Int32 in
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            pipe.fileHandleForReading.readabilityHandler = nil
            if exitCode == 0 {
                relaunchInstalledApp()
            } else {
                failed = true
                busy = false
                status = "Homebrew could not upgrade the app."
            }
        } catch {
            failed = true
            busy = false
            status = "Could not run Homebrew."
        }
    }

    private func runZip(_ offer: UpdateOffer) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sathariels-update-\(UUID().uuidString)", isDirectory: true)
        let zip = root.appendingPathComponent("update.zip")
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            append("Downloading \(offer.version)…\n")
            let (file, response) = try await session.download(from: offer.zip)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.moveItem(at: file, to: zip)
            guard ReleaseChecksum.matches(file: zip, expected: offer.sha256) else {
                failed = true
                busy = false
                status = "The download checksum did not match."
                try? FileManager.default.removeItem(at: root)
                return
            }
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, unpacked.path]
            try unzip.run()
            let unzipStatus = await Task.detached { () -> Int32 in
                unzip.waitUntilExit()
                return unzip.terminationStatus
            }.value
            guard unzipStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.removeItem(at: zip)
            let app = unpacked.appendingPathComponent("Sathariels Browser.app")
            guard FileManager.default.fileExists(atPath: app.path),
                  let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  (plist["CFBundleIdentifier"] as? String) == "com.sathariels.browser",
                  let found = plist["CFBundleShortVersionString"] as? String,
                  VersionCompare.same(found, offer.version) else {
                failed = true
                busy = false
                status = "The downloaded app did not match this browser."
                try? FileManager.default.removeItem(at: root)
                return
            }
            let destination = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
                failed = true
                busy = false
                status = "This copy cannot replace itself. Open the release page instead."
                return
            }
            try swapIn(app, replacing: destination)
        } catch {
            failed = true
            busy = false
            status = "The update could not be downloaded."
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func swapIn(_ source: URL, replacing destination: URL) throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("sathariels-update-\(UUID().uuidString).sh")
        let body = """
        #!/bin/bash
        set -euo pipefail
        pid="$1"
        src="$2"
        dest="$3"
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.2
        done
        parent="$(dirname "$dest")"
        stage="$parent/.sathariels-browser-new"
        rm -rf "$stage"
        /usr/bin/ditto "$src" "$stage"
        rm -rf "$dest"
        mv "$stage" "$dest"
        /usr/bin/xattr -dr com.apple.quarantine "$dest" || true
        /usr/bin/open "$dest"
        rm -rf "$(dirname "$src")"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        flushSessions()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), source.path, destination.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private func relaunchInstalledApp() {
        flushSessions()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func flushSessions() {
        for session in SessionRegistry.shared.all() {
            session.focusedTab?.captureInteractionState()
            session.persist()
        }
        SessionStore.shared.saveNow()
        CrashCenter.markClean()
    }

    private func append(_ text: String) {
        log = String((log + text).suffix(4_000))
    }
}
