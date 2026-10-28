import AppKit
import SwiftUI

struct AddressBarHost: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        if let tab = session.focusedTab {
            AddressBarView(session: session, tab: tab)
        }
    }
}

struct AddressBarView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var prefix = ""
    @State private var completionHost = ""
    @State private var menuOpen = false
    @State private var highlight = -1
    @State private var editing = false
    @State private var showSite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                navButton("chevron.left", help: "Back", enabled: tab.canGoBack == true) { session.back() }
                navButton("chevron.right", help: "Forward", enabled: tab.canGoForward == true) { session.forward() }
                navButton(tab.isLoading == true ? "xmark" : "arrow.clockwise", help: "Reload", enabled: true) {
                    if tab.isLoading == true { tab.stop() } else { session.reloadFocused() }
                }
                omnibox
                Button {
                    guard let url = tab.url else { return }
                    bookmarks.toggle(url: url, title: tab.title)
                } label: {
                    Image(systemName: isBookmarked ? "star.fill" : "star")
                        .foregroundStyle(LumenTheme.amber)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Bookmark")
                Button {
                    showSite.toggle()
                } label: {
                    Image(systemName: "info.square")
                        .foregroundStyle(LumenTheme.sky)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Site settings")
                .accessibilityLabel("Site settings")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if tab.isLoading == true {
                let color = LumenTheme.tabColor(tab.colorIndex)
                GeometryReader { proxy in
                    Rectangle()
                        .fill(color)
                        .frame(width: max(2, proxy.size.width * tab.progress), height: 2)
                }
                .frame(height: 2)
            } else {
                Rectangle().fill(LumenTheme.border).frame(height: 1)
            }
            if showSite, let host = tab.url?.host {
                SitePermissionsEditor(host: host, store: session.permissions, onAutoplayChange: {
                    tab.suspend()
                    tab.wake()
                })
                .padding(8)
            }
            if menuOpen && editing && !suggestions.isEmpty {
                suggestionList
            }
        }
        .background(LumenTheme.bg)
        .onChange(of: session.addressFocusToken) { _, _ in editing = true }
        .onChange(of: session.addressSeed) { _, seed in
            if let seed {
                prefix = seed
                completionHost = ""
                menuOpen = true
                session.addressSeed = nil
            }
        }
        .onChange(of: tab.url) { _, _ in
            if !editing { syncFromTab() }
        }
        .onAppear { syncFromTab() }
    }

    private var omnibox: some View {
        OmniboxField(
            prefix: $prefix,
            completionHost: completionHost,
            focusToken: session.addressFocusToken,
            tint: session.isPrivate ? LumenTheme.coral : LumenTheme.amber,
            onPrefix: { typed in
                prefix = typed
                editing = true
                refreshCompletion()
                menuOpen = !typed.isEmpty
                highlight = -1
            },
            onSubmit: { text in
                editing = false
                menuOpen = false
                commit(text)
            },
            onMove: { delta in
                let count = suggestions.count
                guard count > 0 else { return }
                if highlight < 0 { highlight = 0 } else { highlight = (highlight + delta + count) % count }
            },
            onEscape: {
                menuOpen = false
                editing = false
                syncFromTab()
            }
        )
        .frame(height: 26)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, row in
                Button {
                    activate(row)
                } label: {
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(color(for: row.kind))
                            .frame(width: 8, height: 8)
                        Text(row.title)
                            .font(LumenTheme.monoSmall)
                            .foregroundStyle(LumenTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.kind == .search ? "search" : row.subtitle)
                            .font(LumenTheme.micro)
                            .foregroundStyle(LumenTheme.textDim)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == highlight ? LumenTheme.bgRaised : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(LumenTheme.field)
        .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var suggestions: [Omnibox.Candidate] {
        Omnibox.suggestions(prefix: prefix, entries: session.omniboxEntries(), engine: settings.searchEngine)
    }

    private var isBookmarked: Bool {
        guard let url = tab.url else { return false }
        return bookmarks.contains(url: url)
    }

    private func refreshCompletion() {
        completionHost = Omnibox.inlineHost(prefix: prefix, entries: session.omniboxEntries()) ?? ""
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if highlight >= 0, suggestions.indices.contains(highlight) {
            activate(suggestions[highlight])
            return
        }
        guard let url = AddressResolver.resolve(trimmed, engine: settings.searchEngine) else { return }
        if let existing = session.tabs.first(where: { $0.url?.absoluteString == url.absoluteString }) {
            session.select(existing.id)
        } else {
            session.navigateFocused(to: url)
        }
        syncFromTab()
    }

    private func activate(_ row: Omnibox.Candidate) {
        menuOpen = false
        editing = false
        highlight = -1
        if let tabID = row.tabID {
            session.select(tabID)
            syncFromTab()
            return
        }
        if let raw = row.urlString, let url = URL(string: raw) {
            if let existing = session.tabs.first(where: { $0.url?.absoluteString == url.absoluteString && row.kind != .search }) {
                session.select(existing.id)
            } else {
                session.navigateFocused(to: url)
            }
        }
        syncFromTab()
    }

    private func syncFromTab() {
        prefix = tab.url?.absoluteString ?? ""
        completionHost = ""
        menuOpen = false
    }

    private func color(for kind: Omnibox.Kind) -> Color {
        switch kind {
        case .history: return LumenTheme.amber
        case .bookmark: return LumenTheme.lime
        case .tab: return LumenTheme.teal
        case .search: return LumenTheme.sky
        }
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .foregroundStyle(enabled ? LumenTheme.text : LumenTheme.textDim)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

struct OmniboxField: NSViewRepresentable {
    @Binding var prefix: String
    var completionHost: String
    var focusToken: Int
    var tint: Color
    var onPrefix: (String) -> Void
    var onSubmit: (String) -> Void
    var onMove: (Int) -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(srgbRed: 0.067, green: 0.071, blue: 0.082, alpha: 1)
        field.textColor = NSColor(srgbRed: 0.89, green: 0.90, blue: 0.85, alpha: 1)
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingHead
        field.cell?.sendsActionOnEndEditing = false
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != prefix {
            field.stringValue = prefix
        }
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
        context.coordinator.applyCompletionIfNeeded()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmniboxField
        weak var field: NSTextField?
        var applying = false
        var suppressPrefix: String?
        var lastFocus = 0

        init(_ parent: OmniboxField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard !applying, let field else { return }
            let editor = field.currentEditor() as? NSTextView
            let selected = editor?.selectedRange() ?? NSRange(location: 0, length: 0)
            let full = field.stringValue
            let typed: String
            if selected.length > 0, selected.location + selected.length == (full as NSString).length {
                typed = (full as NSString).substring(with: NSRange(location: 0, length: selected.location))
            } else {
                typed = full
            }
            if suppressPrefix == typed { return }
            suppressPrefix = nil
            parent.onPrefix(typed)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit(control.stringValue)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onMove(1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onMove(-1)
                return true
            }
            let completionSelected = isCompletionSelected(textView)
            if completionSelected && (commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.moveRight(_:))) {
                let end = (control.stringValue as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                suppressPrefix = nil
                parent.onPrefix(control.stringValue)
                return true
            }
            if completionSelected && commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                let typed = currentTyped(textView, string: control.stringValue)
                suppressPrefix = typed
                applying = true
                control.stringValue = typed
                textView.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
                applying = false
                parent.onPrefix(typed)
                return true
            }
            return false
        }

        func applyCompletionIfNeeded() {
            guard let field, field.currentEditor() != nil, let textView = field.currentEditor() as? NSTextView else { return }
            let typed = parent.prefix
            if suppressPrefix == typed { return }
            guard let suffix = Omnibox.completionSuffix(typed: typed, suggestion: parent.completionHost), !suffix.isEmpty else { return }
            let next = typed + suffix
            if field.stringValue == next, isCompletionSelected(textView) { return }
            applying = true
            field.stringValue = next
            textView.setSelectedRange(NSRange(location: (typed as NSString).length, length: (suffix as NSString).length))
            applying = false
        }

        private func isCompletionSelected(_ textView: NSTextView) -> Bool {
            let selected = textView.selectedRange()
            let full = textView.string
            guard selected.length > 0, selected.location + selected.length == (full as NSString).length else { return false }
            return true
        }

        private func currentTyped(_ textView: NSTextView, string: String) -> String {
            let selected = textView.selectedRange()
            if selected.length > 0, selected.location + selected.length == (string as NSString).length {
                return (string as NSString).substring(with: NSRange(location: 0, length: selected.location))
            }
            return string
        }
    }
}
