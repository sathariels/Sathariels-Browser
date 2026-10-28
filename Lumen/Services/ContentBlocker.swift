import CryptoKit
import Foundation
import WebKit

final class ContentBlocker: ObservableObject {
    static let shared = ContentBlocker()

    enum Phase: Equatable {
        case idle
        case loading
        case ready(Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private(set) var blockLists: [WKContentRuleList] = []
    private var cookieList: WKContentRuleList?
    private var started = false
    private var refreshing = false

    var phaseLabel: String {
        switch phase {
        case .idle: return "blocker idle"
        case .loading: return "blocker…"
        case .ready(let count): return "blocker \(count)"
        case .failed: return "blocker failed"
        }
    }

    func applicableLists() -> [WKContentRuleList] {
        var lists: [WKContentRuleList] = []
        if SettingsStore.shared.contentBlocking {
            lists.append(contentsOf: blockLists)
        }
        if SettingsStore.shared.blockThirdPartyCookies, let cookieList {
            lists.append(cookieList)
        }
        return lists
    }

    private init() {}

    /// Does not read or compile the filter JSON. The new-tab window stays idle until a page needs a web view.
    func prepare() {}

    func ensureLoaded() {
        guard !started else { return }
        started = true
        phase = .loading
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.compileCookieRule()
            if await self.loadPrecompiled() {
                if UserDefaults.standard.object(forKey: "blockerListRefresh") == nil {
                    UserDefaults.standard.set(Date(), forKey: "blockerListRefresh")
                }
            } else {
                await self.loadCachedOrBundled()
                if UserDefaults.standard.object(forKey: "blockerListRefresh") == nil {
                    UserDefaults.standard.set(Date(), forKey: "blockerListRefresh")
                }
            }
            await self.refreshFiltersIfDue()
        }
    }

    func precompileBundled(to directory: URL) async {
        let files = bundledFilterFiles()
        guard !files.isEmpty else { return }
        var targets = [directory]
        if let support = precompiledStoreURL() { targets.append(support) }
        for target in targets {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            guard let store = WKContentRuleListStore(url: target) else { continue }
            var identifiers: [String] = []
            var ruleCount = 0
            for (index, file) in files.enumerated() {
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let count = Self.actionCount(source)
                let identifier = "sathariels.prebuilt.\(index)"
                if (try? await compile(source, identifier: identifier, store: store)) != nil {
                    identifiers.append(identifier)
                    ruleCount += count
                }
            }
            guard !identifiers.isEmpty else { continue }
            let manifest: [String: Any] = ["identifiers": identifiers, "count": ruleCount]
            if let data = try? JSONSerialization.data(withJSONObject: manifest) {
                try? data.write(to: target.appendingPathComponent("manifest.json"), options: .atomic)
            }
            if let support = supportDirectory() {
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                try? target.path.write(to: support.appendingPathComponent("precompile-ready"), atomically: true, encoding: .utf8)
            }
            return
        }
    }

    func applyToLiveTabs() {
        SessionRegistry.shared.rebuildLiveWebViews()
    }

    private func compileCookieRule() async {
        let source = """
        [{"trigger":{"url-filter":"^https?://","load-type":["third-party"]},"action":{"type":"block-cookies"}}]
        """
        guard let list = try? await compile(source, identifier: "sathariels.cookies.v1") else { return }
        await MainActor.run { self.cookieList = list }
    }

    private func loadCachedOrBundled() async {
        let identifiers = UserDefaults.standard.stringArray(forKey: "blockerListIDs") ?? []
        if !identifiers.isEmpty, let lists = try? await load(identifiers), lists.count == identifiers.count {
            let count = UserDefaults.standard.integer(forKey: "blockerRuleCount")
            await publish(lists, count: count, rebuild: true)
            return
        }
        let files = bundledFilterFiles()
        guard !files.isEmpty else {
            await publishFailure("blocker rules missing")
            return
        }
        await compileFiles(files, rebuild: true)
    }

    private func refreshFiltersIfDue() async {
        guard let last = UserDefaults.standard.object(forKey: "blockerListRefresh") as? Date else { return }
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let sources = [
            "https://easylist-downloads.adblockplus.org/easylist.txt",
            "https://easylist-downloads.adblockplus.org/easyprivacy.txt",
        ]
        var downloads: [URL] = []
        defer { downloads.forEach { try? FileManager.default.removeItem(at: $0) } }
        for raw in sources {
            guard let url = URL(string: raw), let file = await download(url) else { continue }
            downloads.append(file)
        }
        guard !downloads.isEmpty, let directory = filterDirectory() else { return }
        let count = (try? FilterListCompiler.writeChunks(from: downloads, to: directory)) ?? 0
        guard count > 0 else { return }
        let files = directoryFiles(directory)
        await compileFiles(files, rebuild: false)
        UserDefaults.standard.set(Date(), forKey: "blockerListRefresh")
        UserDefaults.standard.set(count, forKey: "blockerRuleCount")
    }

    private func compileFiles(_ files: [URL], rebuild: Bool) async {
        var lists: [WKContentRuleList] = []
        var identifiers: [String] = []
        var ruleCount = 0
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            ruleCount += Self.actionCount(source)
            let digest = SHA256.hash(data: Data(source.utf8))
            let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
            let identifier = "sathariels.blocker.\(suffix)"
            if let list = try? await compile(source, identifier: identifier) {
                lists.append(list)
                identifiers.append(identifier)
            }
        }
        guard !lists.isEmpty else {
            if rebuild { await publishFailure("blocker failed to compile") }
            return
        }
        UserDefaults.standard.set(identifiers, forKey: "blockerListIDs")
        UserDefaults.standard.set(ruleCount, forKey: "blockerRuleCount")
        await publish(lists, count: ruleCount, rebuild: rebuild)
    }

    private func loadPrecompiled() async -> Bool {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("PrecompiledRules", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path),
              let manifest = try? Data(contentsOf: bundled.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let identifiers = json["identifiers"] as? [String], !identifiers.isEmpty,
              let destination = precompiledStoreURL() else { return false }
        let copiedMarker = destination.appendingPathComponent("manifest.json")
        if !FileManager.default.fileExists(atPath: copiedMarker.path) {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: bundled, to: destination)
        }
        guard let store = WKContentRuleListStore(url: destination) else { return false }
        var lists: [WKContentRuleList] = []
        for identifier in identifiers {
            if let list = try? await store.contentRuleList(forIdentifier: identifier) {
                lists.append(list)
            }
        }
        guard lists.count == identifiers.count else { return false }
        let count = json["count"] as? Int ?? lists.count
        await publish(lists, count: count, rebuild: true)
        return true
    }

    private func compile(_ source: String, identifier: String) async throws -> WKContentRuleList {
        guard let store = await WKContentRuleListStore.default() else { throw CocoaError(.coderInvalidValue) }
        return try await compile(source, identifier: identifier, store: store)
    }

    private func compile(_ source: String, identifier: String, store: WKContentRuleListStore) async throws -> WKContentRuleList {
        if let existing = try? await store.contentRuleList(forIdentifier: identifier) {
            return existing
        }
        guard let compiled = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) else {
            throw CocoaError(.coderInvalidValue)
        }
        return compiled
    }

    private func load(_ identifiers: [String]) async throws -> [WKContentRuleList] {
        guard let store = await WKContentRuleListStore.default() else { return [] }
        var lists: [WKContentRuleList] = []
        for identifier in identifiers {
            if let list = try? await store.contentRuleList(forIdentifier: identifier) {
                lists.append(list)
            }
        }
        return lists
    }

    private func publish(_ lists: [WKContentRuleList], count: Int, rebuild: Bool) async {
        await MainActor.run {
            let first = self.blockLists.isEmpty
            self.blockLists = lists
            self.phase = .ready(count)
            if rebuild && first {
                self.applyToLiveTabs()
            }
        }
    }

    private func publishFailure(_ text: String) async {
        await MainActor.run {
            if self.blockLists.isEmpty {
                self.phase = .failed(text)
            }
        }
    }

    private func bundledFilterFiles() -> [URL] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let filters = urls.filter { $0.lastPathComponent.hasPrefix("blocker-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !filters.isEmpty { return filters }
        if let legacy = Bundle.main.url(forResource: "blocker-rules", withExtension: "json") {
            return [legacy]
        }
        return []
    }

    private func supportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SatharielsBrowser", isDirectory: true)
    }

    private func precompiledStoreURL() -> URL? {
        supportDirectory()?.appendingPathComponent("PrecompiledRules", isDirectory: true)
    }

    private func filterDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("SatharielsBrowser/filters", isDirectory: true)
    }

    private func directoryFiles(_ directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("blocker-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func actionCount(_ source: String) -> Int {
        var count = 0
        var search = source.startIndex
        while let found = source.range(of: "\"action\"", range: search..<source.endIndex) {
            count += 1
            search = found.upperBound
        }
        return count
    }

    private func download(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 1_000, data.count < 12_000_000 else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
