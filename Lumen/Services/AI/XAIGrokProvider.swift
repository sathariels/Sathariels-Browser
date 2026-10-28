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

    func complete(messages: [AIMessage], model: String, apiKey: String, maxTokens: Int) async throws -> String {
        let json = try await post(
            body: [
                "model": model.isEmpty ? "grok-4.7" : model,
                "stream": false,
                "max_tokens": maxTokens,
                "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
            ],
            apiKey: apiKey,
            conversationID: nil
        )
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIProviderError(message: "Grok returned an empty completion.")
        }
        return content
    }

    func completeWithTools(messages: [[String: Any]], tools: [[String: Any]], model: String, apiKey: String, conversationID: String) async throws -> ToolTurn {
        let json = try await post(
            body: [
                "model": model.isEmpty ? "grok-4.7" : model,
                "stream": false,
                "max_tokens": 900,
                "messages": messages,
                "tools": tools
            ],
            apiKey: apiKey,
            conversationID: conversationID
        )
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIProviderError(message: "Grok returned no message.")
        }
        let text = message["content"] as? String ?? ""
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { raw -> ToolCall? in
            let function = raw["function"] as? [String: Any]
            let name = function?["name"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            let id = (raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call-\(name)"
            return ToolCall(id: id, name: name, arguments: function?["arguments"] as? String ?? "{}")
        }
        return ToolTurn(text: text, calls: calls)
    }

    private func post(body: [String: Any], apiKey: String, conversationID: String?) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = conversationID == nil ? 12 : 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let conversationID {
            request.setValue(conversationID, forHTTPHeaderField: "x-grok-conv-id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError(message: "No response from xAI.")
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError(message: Self.message(from: data, status: http.statusCode, key: apiKey))
        }
        return json
    }
}

struct ToolCall {
    var id: String
    var name: String
    var arguments: String
}

struct ToolTurn {
    var text: String
    var calls: [ToolCall]
}
