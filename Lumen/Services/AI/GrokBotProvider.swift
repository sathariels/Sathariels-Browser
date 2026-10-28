import Foundation

/// Grok Bot is a separate desktop assistant. It does not publish an HTTP API
/// that Lumen can call, so this type is a placeholder.
///
/// TODO: When Grok Bot documents an official API, implement `streamReply` here
/// and only then. Do not guess endpoints, authentication, or message schemas.
final class GrokBotProvider: AIProvider {
    static let id = "grokbot"
    let id = "grokbot"
    let displayName = "Grok Bot"
    let isStub = true

    func streamReply(
        messages: [AIMessage],
        model: String,
        apiKey: String,
        conversationID: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIProviderError(
                message: "Grok Bot has no official API wired up. Open it from the sidebar instead."
            ))
        }
    }
}
