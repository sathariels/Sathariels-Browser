import SwiftUI

struct GrokPanel: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var chat: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(title: "Grok", color: LumenTheme.violet)
                Spacer()
                Button("Clear") { chat.clear() }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.textDim))
                    .padding(.trailing, 8)
            }
            if session.isPrivate {
                Text("Private window. This chat is kept in memory only.")
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.coral)
                    .padding(.horizontal, 8)
            }
            providerRow
            if chat.provider.isStub {
                stubNote
            } else {
                transcript
                composer
            }
        }
        .background(LumenTheme.bg)
        .overlay(Rectangle().strokeBorder(LumenTheme.violet.opacity(0.5), lineWidth: 1))
    }

    private var providerRow: some View {
        HStack(spacing: 6) {
            Button("xAI") { chat.providerID = XAIGrokProvider.providerID }
                .buttonStyle(LumenButtonStyle(tint: chat.providerID == XAIGrokProvider.providerID ? LumenTheme.violet : LumenTheme.textDim))
            Button("Grok Bot") { chat.providerID = GrokBotProvider.id }
                .buttonStyle(LumenButtonStyle(tint: chat.providerID == GrokBotProvider.id ? LumenTheme.violet : LumenTheme.textDim))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var stubNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grok Bot has no official API. Lumen will not invent one.")
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.text)
            Text("Use the sidebar to open the app, or send the current page title, URL, and selection to the clipboard and launch the configured URL.")
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.textDim)
            Button("Open Grok Bot") { session.openGrokBot(sendPage: false) }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.violet))
            Button("Send page") { session.openGrokBot(sendPage: true) }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.teal))
            Spacer()
        }
        .padding(8)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if chat.messages.isEmpty {
                    Text("Ask about the open page, or turn off Page to ask something else.")
                        .font(LumenTheme.monoSmall)
                        .foregroundStyle(LumenTheme.textDim)
                }
                ForEach(chat.messages) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.role == .user ? "YOU" : "GROK")
                            .font(LumenTheme.micro)
                            .foregroundStyle(message.role == .user ? LumenTheme.amber : LumenTheme.violet)
                        Text(message.content.isEmpty ? "…" : message.content)
                            .font(LumenTheme.monoSmall)
                            .foregroundStyle(LumenTheme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(6)
                    .overlay(Rectangle().strokeBorder(message.role == .user ? LumenTheme.amber.opacity(0.7) : LumenTheme.violet.opacity(0.7), lineWidth: 1))
                }
                if let error = chat.errorText {
                    Text(error)
                        .font(LumenTheme.micro)
                        .foregroundStyle(LumenTheme.coral)
                }
            }
            .padding(8)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $chat.includePage) {
                Text("Page")
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.teal)
            }
            .toggleStyle(.checkbox)
            TextField("Ask Grok", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.text)
                .lineLimit(2...5)
                .padding(6)
                .background(LumenTheme.field)
                .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
            HStack {
                Button(chat.sending ? "Stop" : "Send") {
                    if chat.sending {
                        chat.cancel()
                    } else {
                        send()
                    }
                }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.violet))
                Spacer()
                Text(SettingsStore.shared.grokModel)
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.textDim)
            }
        }
        .padding(8)
    }

    private func send() {
        guard let tab = session.focusedTab else {
            chat.send(pageTitle: "", pageURL: "", selection: "", pageText: "")
            return
        }
        if !chat.includePage {
            chat.send(pageTitle: tab.title, pageURL: tab.url?.absoluteString ?? "", selection: "", pageText: "")
            return
        }
        tab.pageSnapshot { title, selection, text in
            chat.send(
                pageTitle: title,
                pageURL: tab.url?.absoluteString ?? "",
                selection: selection,
                pageText: text
            )
        }
    }
}
