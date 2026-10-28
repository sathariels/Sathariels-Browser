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

    var phaseLabel: String {
        switch phase {
        case .idle: return "blocker idle"
        case .loading: return "blocker…"
        case .ready(let count): return "blocker \(count)"
        case .failed: return "blocker failed"
        }
    }
    private(set) var ruleList: WKContentRuleList?
    private var started = false

    private init() {}

    func prepare() {
        guard !started else { return }
        started = true
        phase = .loading
        Task { @MainActor in
            do {
                let list = try await Self.compile()
                self.ruleList = list
                let count = Self.ruleCount()
                self.phase = .ready(count)
                self.applyToLiveTabs()
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func applyToLiveTabs() {
        SessionRegistry.shared.rebuildLiveWebViews()
    }

    private static func ruleCount() -> Int {
        guard let url = Bundle.main.url(forResource: "blocker-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return array.count
    }

    private static func compile() async throws -> WKContentRuleList {
        guard let url = Bundle.main.url(forResource: "blocker-rules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let digest = SHA256.hash(data: Data(source.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let identifier = "sathariels.blocker.\(suffix)"
        guard let store = await WKContentRuleListStore.default() else {
            throw CocoaError(.coderInvalidValue)
        }
        // A cache miss throws on WebKit; it must fall through to compilation.
        if let existing = try? await store.contentRuleList(forIdentifier: identifier) {
            return existing
        }
        guard let compiled = try await store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: source
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        return compiled
    }
}
