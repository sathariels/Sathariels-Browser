import Foundation
import WebKit

enum PageAgent {
    private static let maxRounds = 6

    static func run(chat: ChatStore, session: BrowserSession, assistantID: UUID, runID: UUID) async {
        var api: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        let history = await MainActor.run { chat.messages }
        for message in history.suffix(8) where message.role == .user || message.role == .assistant {
            let text = String(message.content.prefix(1_500))
            if text.isEmpty { continue }
            api.append(["role": message.role.rawValue, "content": text])
        }
        guard let apiKey = APIKeyStore.load(), !apiKey.isEmpty else {
            await MainActor.run {
                chat.sending = false
                chat.errorText = "Add an xAI API key in Settings. It stays in the Keychain."
            }
            return
        }
        let model = SettingsStore.shared.grokModel
        for _ in 0..<maxRounds {
            if await stopped(chat, runID) { return }
            let turn: ToolTurn
            do {
                turn = try await AIProviders.grok.completeWithTools(
                    messages: api,
                    tools: toolDefinitions,
                    model: model,
                    apiKey: apiKey,
                    conversationID: chat.conversationID
                )
            } catch {
                await MainActor.run {
                    chat.sending = false
                    if (error as? URLError)?.code != .cancelled {
                        chat.errorText = error.localizedDescription
                    }
                }
                return
            }
            if await stopped(chat, runID) { return }
            if !turn.text.isEmpty {
                await MainActor.run { append(chat, id: assistantID, turn.text) }
            }
            if turn.calls.isEmpty { break }
            var assistant: [String: Any] = [
                "role": "assistant",
                "content": turn.text,
                "tool_calls": turn.calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.arguments]
                    ]
                }
            ]
            if turn.text.isEmpty { assistant["content"] = "" }
            api.append(assistant)
            for call in turn.calls.prefix(3) {
                if await stopped(chat, runID) { return }
                let args = parse(call.arguments)
                let preview = previewLine(name: call.name, args: args)
                await MainActor.run {
                    chat.messages.append(AIMessage(id: UUID(), role: .step, content: preview))
                    chat.trimSoft()
                }
                let result = await perform(call.name, args: args, session: session, chat: chat)
                if await stopped(chat, runID) { return }
                let clipped = String(result.prefix(3_500))
                await MainActor.run {
                    chat.messages.append(AIMessage(id: UUID(), role: .step, content: String(clipped.prefix(180))))
                }
                api.append(["role": "tool", "tool_call_id": call.id, "content": clipped])
            }
            if api.count > 16 {
                api.removeFirst(api.count - 16)
                if (api.first?["role"] as? String) != "system" {
                    api.insert(["role": "system", "content": systemPrompt], at: 0)
                }
            }
        }
        await MainActor.run { chat.sending = false }
    }

    private static func stopped(_ chat: ChatStore, _ runID: UUID) async -> Bool {
        if Task.isCancelled { return true }
        return await MainActor.run { chat.runID != runID || !chat.sending }
    }

    private static func append(_ chat: ChatStore, id: UUID, _ text: String) {
        guard let index = chat.messages.firstIndex(where: { $0.id == id }) else { return }
        if chat.messages[index].content.count < 8_000 {
            chat.messages[index].content += text
        }
    }

    private static func perform(_ name: String, args: [String: Any], session: BrowserSession, chat: ChatStore) async -> String {
        switch name {
        case "read_page":
            return await read(session)
        case "click":
            return await click(intArg(args, "index") ?? -1, session: session, chat: chat)
        case "type_text":
            return await typeText(intArg(args, "index") ?? -1, text: stringArg(args, "text"), session: session, chat: chat)
        case "scroll":
            return await scroll(stringArg(args, "direction"), session: session)
        case "navigate":
            return await navigate(stringArg(args, "url"), session: session, newTab: false)
        case "new_tab":
            return await navigate(stringArg(args, "url"), session: session, newTab: true)
        default:
            return "Unknown tool \(name)."
        }
    }

    private static func read(_ session: BrowserSession) async -> String {
        guard let webView = await MainActor.run(body: { session.focusedTab?.webView }) else {
            return "No page is loaded."
        }
        _ = await eval(webView, "if(!window.__lumenAgent){\(PageScripts.agentInstall)}")
        guard let value = await eval(webView, "window.__lumenAgent.read()") else { return "Could not read the page." }
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              var text = String(data: data, encoding: .utf8) else { return "Could not read the page." }
        if text.count > 3_500 { text = String(text.prefix(3_500)) }
        return text
    }

    private static func click(_ index: Int, session: BrowserSession, chat: ChatStore) async -> String {
        guard let info = await describe(index, session: session) else { return "Element \(index) is not in the last page read." }
        let text = info["text"] as? String ?? ""
        let type = info["type"] as? String ?? ""
        if AgentSafety.clickNeedsConfirm(type: type, text: text) {
            let ok = await confirm(chat, title: "Allow this click?", detail: text.isEmpty ? "Control \(index)" : text)
            if !ok { return "The user denied the click." }
        }
        guard let webView = await MainActor.run(body: { session.focusedTab?.webView }) else { return "No page is loaded." }
        _ = await eval(webView, "window.__lumenAgent.click(\(index))")
        return "Clicked \(index)."
    }

    private static func typeText(_ index: Int, text: String, session: BrowserSession, chat: ChatStore) async -> String {
        let clipped = String(text.prefix(500))
        guard !clipped.isEmpty else { return "Nothing to type." }
        guard let info = await describe(index, session: session) else { return "Element \(index) is not in the last page read." }
        let type = info["type"] as? String ?? ""
        let name = info["name"] as? String ?? ""
        let auto = info["autocomplete"] as? String ?? ""
        let secret = (info["secret"] as? Bool) ?? (info["secret"] as? NSNumber)?.boolValue ?? false
        if secret || AgentSafety.isPasswordField(type: type, autocomplete: auto) || AgentSafety.typeNeedsConfirm(type: type, name: name, autocomplete: auto) {
            let host = await MainActor.run { session.focusedTab?.url?.host ?? "this site" }
            let ok = await confirm(
                chat,
                title: "Type into a sensitive field?",
                detail: "This may enter a credential or payment detail on \(host). The current field value is not read."
            )
            if !ok { return "The user denied typing into this field." }
        }
        guard let webView = await MainActor.run(body: { session.focusedTab?.webView }) else { return "No page is loaded." }
        let literal = JSEncode.string(clipped)
        _ = await eval(webView, "window.__lumenAgent.type(\(index), \(literal))")
        return "Typed into field \(index)."
    }

    private static func scroll(_ direction: String, session: BrowserSession) async -> String {
        let dir = ["up", "down", "top"].contains(direction) ? direction : "down"
        guard let webView = await MainActor.run(body: { session.focusedTab?.webView }) else { return "No page is loaded." }
        _ = await eval(webView, "if(!window.__lumenAgent){\(PageScripts.agentInstall)}")
        _ = await eval(webView, "window.__lumenAgent.scroll(\(JSEncode.string(dir)))")
        return "Scrolled \(dir)."
    }

    private static func navigate(_ raw: String, session: BrowserSession, newTab: Bool) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            return "Only http and https URLs are opened."
        }
        await MainActor.run {
            if newTab { session.newTab(url: url) } else { session.navigateFocused(to: url) }
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        return newTab ? "Opened \(url.host ?? url.absoluteString) in a new tab." : "Navigated to \(url.host ?? url.absoluteString)."
    }

    private static func describe(_ index: Int, session: BrowserSession) async -> [String: Any]? {
        guard let webView = await MainActor.run(body: { session.focusedTab?.webView }) else { return nil }
        _ = await eval(webView, "if(!window.__lumenAgent){\(PageScripts.agentInstall)}")
        let value = await eval(webView, "window.__lumenAgent.describe(\(index))")
        return value as? [String: Any]
    }

    private static func confirm(_ chat: ChatStore, title: String, detail: String) async -> Bool {
        await chat.requestConfirm(title: title, detail: detail)
    }

    private static func eval(_ webView: WKWebView, _ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                webView.evaluateJavaScript(script) { value, _ in
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private static func parse(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private static func intArg(_ args: [String: Any], _ key: String) -> Int? {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? NSNumber { return value.intValue }
        return nil
    }

    private static func stringArg(_ args: [String: Any], _ key: String) -> String {
        args[key] as? String ?? ""
    }

    private static func previewLine(name: String, args: [String: Any]) -> String {
        switch name {
        case "read_page": return "Read page"
        case "click": return "Click \(intArg(args, "index") ?? -1)"
        case "type_text": return "Type into \(intArg(args, "index") ?? -1)"
        case "scroll": return "Scroll \(stringArg(args, "direction"))"
        case "navigate": return "Go to \(stringArg(args, "url").prefix(80))"
        case "new_tab": return "New tab \(stringArg(args, "url").prefix(80))"
        default: return name
        }
    }

    private static let systemPrompt = """
    You are Grok inside Lumen, acting on the focused tab. Use tools when the user wants something done on the page. \
    Summarize by calling read_page and then writing the summary yourself. \
    Password values are never included. Do not try to read them. \
    Clicks that submit, pay, send, or sign in, and typing into credential or payment fields, wait for the user to allow them. \
    Use element indexes from the latest read_page. Stop when the task is done.
    """

    private static let toolDefinitions: [[String: Any]] = [
        tool("read_page", "Read the focused tab. Returns a short text excerpt and up to 24 elements. Password values are omitted.", [:]),
        tool("click", "Click an element by the index from read_page.", ["index": intProp("Element index")]),
        tool("type_text", "Replace the text of an input or textarea by index. Does not read the previous value.", [
            "index": intProp("Element index"),
            "text": stringProp("Text to enter")
        ]),
        tool("scroll", "Scroll the page.", ["direction": stringProp("up, down, or top")]),
        tool("navigate", "Load an http(s) URL in the focused tab.", ["url": stringProp("Absolute http(s) URL")]),
        tool("new_tab", "Open an http(s) URL in a new tab.", ["url": stringProp("Absolute http(s) URL")])
    ]

    private static func intProp(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func stringProp(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties
                ]
            ]
        ]
    }
}

enum JSEncode {
    static func string(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8), encoded.count >= 2 else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }
}
