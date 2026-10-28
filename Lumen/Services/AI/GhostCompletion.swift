import Foundation

/// Short, debounced Grok completions. Callers cancel stale work themselves.
enum GhostCompletion {
    private static var fieldGeneration = 0

    static func bumpField() -> Int {
        fieldGeneration += 1
        return fieldGeneration
    }

    static func fieldIsCurrent(_ token: Int) -> Bool {
        token == fieldGeneration
    }

    static func address(prefix: String, hints: [String]) async -> String? {
        let typed = String(prefix.prefix(160))
        guard typed.count >= 2, let key = APIKeyStore.load(), !key.isEmpty else { return nil }
        let sites = hints.prefix(8).map { String($0.prefix(40)) }.joined(separator: ", ")
        let prompt = """
        Complete this browser address bar. Reply with the full text only, no quotes and no explanation. \
        If you are unsure, reply with the prefix unchanged.
        Prefix: \(typed)
        Known sites: \(sites)
        """
        return await finish(prompt: prompt, prefix: typed, apiKey: key)
    }

    static func field(prefix: String, label: String) async -> String? {
        let typed = String(prefix.prefix(180))
        guard typed.count >= 2, let key = APIKeyStore.load(), !key.isEmpty else { return nil }
        let prompt = """
        Complete text the user is typing into a web form field. Reply with the full field value only, no quotes. \
        Do not invent passwords, card numbers, or one-time codes. If unsure, reply with the prefix unchanged.
        Label: \(String(label.prefix(80)))
        Prefix: \(typed)
        """
        return await finish(prompt: prompt, prefix: typed, apiKey: key)
    }

    private static func finish(prompt: String, prefix: String, apiKey: String) async -> String? {
        let reply = try? await AIProviders.grok.complete(
            messages: [AIMessage(id: UUID(), role: .user, content: prompt)],
            model: SettingsStore.shared.grokModel,
            apiKey: apiKey,
            maxTokens: 40
        )
        guard var reply else { return nil }
        reply = reply.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.hasPrefix("\""), reply.hasSuffix("\""), reply.count >= 2 {
            reply = String(reply.dropFirst().dropLast())
        }
        reply = String(reply.prefix(160))
        guard Omnibox.completionSuffix(typed: prefix, suggestion: reply) != nil else { return nil }
        return reply
    }
}
