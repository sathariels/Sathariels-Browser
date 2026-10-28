import Foundation

struct AIProviderError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

protocol AIProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// True when this provider must not hit the network.
    var isStub: Bool { get }
    func streamReply(
        messages: [AIMessage],
        model: String,
        apiKey: String,
        conversationID: String
    ) -> AsyncThrowingStream<String, Error>
    func complete(messages: [AIMessage], model: String, apiKey: String, maxTokens: Int) async throws -> String
    func completeWithTools(messages: [[String: Any]], tools: [[String: Any]], model: String, apiKey: String, conversationID: String) async throws -> ToolTurn
}

extension AIProvider {
    func complete(messages: [AIMessage], model: String, apiKey: String, maxTokens: Int) async throws -> String {
        throw AIProviderError(message: "This provider does not complete text.")
    }

    func completeWithTools(messages: [[String: Any]], tools: [[String: Any]], model: String, apiKey: String, conversationID: String) async throws -> ToolTurn {
        throw AIProviderError(message: "This provider cannot use tools.")
    }
}

enum AIProviders {
    static let grok = XAIGrokProvider()
    static let grokBot = GrokBotProvider()

    static func find(_ id: String) -> AIProvider {
        id == GrokBotProvider.id ? grokBot : grok
    }
}

final class ChatStore: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var draft = ""
    @Published var includePage = true
    @Published var act = true
    @Published var sending = false
    @Published var errorText: String?
    @Published var pendingTitle: String?
    @Published var pendingDetail: String?
    @Published var providerID = XAIGrokProvider.providerID

    let isPrivate: Bool
    let conversationID = UUID().uuidString
    private(set) var runID = UUID()
    private var task: Task<Void, Never>?
    private var pendingResume: ((Bool) -> Void)?

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
    }

    var provider: AIProvider { AIProviders.find(providerID) }

    func requestConfirm(title: String, detail: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                if !self.sending {
                    continuation.resume(returning: false)
                    return
                }
                if let pending = self.pendingResume {
                    self.pendingResume = nil
                    pending(false)
                }
                self.pendingTitle = title
                self.pendingDetail = detail
                self.pendingResume = { allow in
                    continuation.resume(returning: allow)
                }
            }
        }
    }

    func resolvePending(_ allow: Bool) {
        pendingResume?(allow)
        pendingResume = nil
        pendingTitle = nil
        pendingDetail = nil
    }

    func send(pageTitle: String, pageURL: String, selection: String, pageText: String, session: BrowserSession?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !sending else { return }
        if provider.isStub {
            errorText = "Grok Bot has no official API. Use the Grok Bot button in the sidebar to open the app."
            return
        }
        guard let apiKey = APIKeyStore.load(), !apiKey.isEmpty else {
            errorText = "Add an xAI API key in Settings. It stays in the Keychain."
            return
        }
        errorText = nil
        let agentAllowed = act && session != nil && !provider.isStub && (!isPrivate || SettingsStore.shared.agentInPrivate)
        var outbound = question
        if !agentAllowed && includePage && (!pageURL.isEmpty || !pageText.isEmpty || !selection.isEmpty) {
            outbound = """
            [Page]
            Title: \(pageTitle)
            URL: \(pageURL)
            Selection: \(selection.prefix(1500))

            \(pageText.prefix(6000))

            [Question]
            \(question)
            """
        }
        messages.append(AIMessage(id: UUID(), role: .user, content: question))
        let assistantID = UUID()
        messages.append(AIMessage(id: assistantID, role: .assistant, content: ""))
        draft = ""
        sending = true
        if messages.count > 30 {
            messages.removeFirst(messages.count - 30)
        }
        var payload = Array(messages.dropLast())
        if let last = payload.indices.last, payload[last].role == .user {
            payload[last].content = outbound
        }
        let model = SettingsStore.shared.grokModel
        let conversation = conversationID
        task?.cancel()
        runID = UUID()
        let currentRun = runID
        if agentAllowed, let session {
            task = Task { [weak self, weak session] in
                guard let self, let session else {
                    await MainActor.run { self?.sending = false }
                    return
                }
                await PageAgent.run(chat: self, session: session, assistantID: assistantID, runID: currentRun)
            }
            return
        }
        task = Task { [weak self] in
            let stream = self?.provider.streamReply(
                messages: [AIMessage(id: UUID(), role: .system, content: Self.systemPrompt)] + payload,
                model: model,
                apiKey: apiKey,
                conversationID: conversation
            )
            guard let stream else { return }
            do {
                for try await token in stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        guard let self, let index = self.messages.firstIndex(where: { $0.id == assistantID }) else { return }
                        if self.messages[index].content.count < 32_000 {
                            self.messages[index].content += token
                        }
                    }
                }
                await MainActor.run {
                    self?.sending = false
                }
            } catch {
                await MainActor.run {
                    self?.sending = false
                    if (error as? URLError)?.code != .cancelled {
                        self?.errorText = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancel() {
        runID = UUID()
        task?.cancel()
        resolvePending(false)
        sending = false
    }

    func clear() {
        runID = UUID()
        task?.cancel()
        resolvePending(false)
        messages = []
        sending = false
        errorText = nil
        pendingTitle = nil
    }

    func trimSoft() {
        if messages.count > 16 { messages = Array(messages.suffix(16)) }
    }

    func trimHard() {
        messages = Array(messages.suffix(6))
    }

    private static let systemPrompt = """
    You are Grok inside Lumen, a small macOS browser. Be direct. \
    When a page excerpt is included, use only that excerpt and do not pretend you fetched the live page. \
    The excerpt may be truncated.
    """
}
