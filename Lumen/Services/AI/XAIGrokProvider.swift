import Foundation

/// OpenAI-compatible chat completions at https://api.x.ai/v1.
/// The API key is passed in at call time and is never logged.
final class XAIGrokProvider: AIProvider {
    static let providerID = "xai"
    let id = XAIGrokProvider.providerID
    let displayName = "Grok (xAI)"
    let isStub = false
    private let endpoint = URL(string: "https://api.x.ai/v1/chat/completions")!

    func streamReply(
        messages: [AIMessage],
        model: String,
        apiKey: String,
        conversationID: String
    ) -> AsyncThrowingStream<String, Error> {
        let endpoint = endpoint
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 90
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(conversationID, forHTTPHeaderField: "x-grok-conv-id")
                    let body: [String: Any] = [
                        "model": model.isEmpty ? "grok-4.7" : model,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError(message: "No response from xAI.")
                    }
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 4_000 { break }
                        }
                        throw AIProviderError(message: Self.message(from: data, status: http.statusCode, key: apiKey))
                    }
                    var emitted = 0
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let token = Self.delta(payload) else { continue }
                        emitted += token.count
                        continuation.yield(token)
                        if emitted > 32_000 { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func delta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    private static func message(from data: Data, status: Int, key: String) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nested = json?["error"] as? [String: Any]
        var text = (nested?["message"] as? String) ?? "xAI returned HTTP \(status)."
        if !key.isEmpty { text = text.replacingOccurrences(of: key, with: "…") }
        return String(text.prefix(300))
    }
}
