import Foundation

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var searchEngine: SearchEngine { didSet { save() } }
    @Published var suspendMinutes: Int { didSet { save() } }
    @Published var contentBlocking: Bool { didSet { save(); ContentBlocker.shared.applyToLiveTabs() } }
    @Published var restoreSession: Bool { didSet { save(); if !restoreSession { SessionStore.shared.forget() } } }
    @Published var clipboardCapture: Bool { didSet { save(); ClipboardStore.shared.setCaptureEnabled(clipboardCapture) } }
    @Published var homePage: String { didSet { save() } }
    @Published var grokModel: String { didSet { save() } }
    @Published var grokBotURL: String { didSet { save() } }
    @Published var addressAIGhost: Bool { didSet { save() } }
    @Published var pageFieldGhost: Bool { didSet { save(); SessionRegistry.shared.rebuildLiveWebViews() } }
    @Published var agentInPrivate: Bool { didSet { save() } }
    @Published var passwordNeverHosts: [String] { didSet { save() } }

    private let defaults = UserDefaults.standard
    private var ready = false

    private init() {
        let engine = defaults.string(forKey: "searchEngine").flatMap(SearchEngine.init(rawValue:)) ?? .duckDuckGo
        searchEngine = engine
        let minutes = defaults.integer(forKey: "suspendMinutes")
        suspendMinutes = minutes == 0 ? 10 : min(180, max(1, minutes))
        if defaults.object(forKey: "contentBlocking") == nil {
            contentBlocking = true
        } else {
            contentBlocking = defaults.bool(forKey: "contentBlocking")
        }
        if defaults.object(forKey: "restoreSession") == nil {
            restoreSession = true
        } else {
            restoreSession = defaults.bool(forKey: "restoreSession")
        }
        if defaults.object(forKey: "clipboardCapture") == nil {
            clipboardCapture = true
        } else {
            clipboardCapture = defaults.bool(forKey: "clipboardCapture")
        }
        homePage = defaults.string(forKey: "homePage") ?? "https://duckduckgo.com"
        let model = defaults.string(forKey: "grokModel") ?? ""
        grokModel = model.isEmpty ? "grok-4.7" : model
        let bot = defaults.string(forKey: "grokBotURL") ?? ""
        grokBotURL = bot.isEmpty ? "grokbot://" : bot
        addressAIGhost = defaults.bool(forKey: "addressAIGhost")
        pageFieldGhost = defaults.bool(forKey: "pageFieldGhost")
        agentInPrivate = defaults.bool(forKey: "agentInPrivate")
        passwordNeverHosts = defaults.stringArray(forKey: "passwordNeverHosts") ?? []
        ready = true
    }

    func neverSavePasswords(for host: String) -> Bool {
        passwordNeverHosts.contains(host.lowercased())
    }

    func blockPasswordSaves(for host: String) {
        let key = host.lowercased()
        guard !passwordNeverHosts.contains(key) else { return }
        passwordNeverHosts.append(key)
    }

    private func save() {
        guard ready else { return }
        defaults.set(searchEngine.rawValue, forKey: "searchEngine")
        defaults.set(suspendMinutes, forKey: "suspendMinutes")
        defaults.set(contentBlocking, forKey: "contentBlocking")
        defaults.set(restoreSession, forKey: "restoreSession")
        defaults.set(clipboardCapture, forKey: "clipboardCapture")
        defaults.set(homePage, forKey: "homePage")
        defaults.set(grokModel, forKey: "grokModel")
        defaults.set(grokBotURL, forKey: "grokBotURL")
        defaults.set(addressAIGhost, forKey: "addressAIGhost")
        defaults.set(pageFieldGhost, forKey: "pageFieldGhost")
        defaults.set(agentInPrivate, forKey: "agentInPrivate")
        defaults.set(passwordNeverHosts, forKey: "passwordNeverHosts")
    }
}

enum APIKeyStore {
    private static let service = "app.lumen.browser"
    private static let account = "xai-api-key"

    static var isSet: Bool { KeychainStore.get(service: service, account: account) != nil }

    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        try KeychainStore.set(data, service: service, account: account)
    }

    static func load() -> String? {
        guard let data = KeychainStore.get(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        KeychainStore.delete(service: service, account: account)
    }
}
