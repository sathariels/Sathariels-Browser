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
    @State private var ghostSuffix = ""
    @State private var dismissedPrefix: String?
    @State private var aiQuery = ""
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
                ghostSuffix = ""
                dismissedPrefix = nil
                aiQuery = ""
                menuOpen = true
                session.addressSeed = nil
            }
        }
        .onChange(of: tab.url) { _, _ in
            if !editing { syncFromTab() }
        }
        .onAppear { syncFromTab() }
        .task(id: aiQuery) {
            let typed = aiQuery
            guard typed.count >= 2, SettingsStore.shared.addressAIGhost, !session.isPrivate, APIKeyStore.isSet else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let hints = Array(session.omniboxEntries().prefix(8).map(\.host))
            let full = await GhostCompletion.address(prefix: typed, hints: hints)
            guard !Task.isCancelled, prefix == typed, dismissedPrefix != typed else { return }
            if let full, let suffix = Omnibox.completionSuffix(typed: typed, suggestion: full), !suffix.isEmpty {
                ghostSuffix = suffix
            }
        }
    }

    private var omnibox: some View {
        OmniboxField(
            prefix: $prefix,
            ghostSuffix: ghostSuffix,
            focusToken: session.addressFocusToken,
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
                ghostSuffix = ""
                aiQuery = ""
                syncFromTab()
            },
            onDismissGhost: {
                dismissedPrefix = prefix
                ghostSuffix = ""
                aiQuery = ""
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
        let typed = prefix
        if dismissedPrefix == typed {
            ghostSuffix = ""
            return
        }
        dismissedPrefix = nil
        let host = Omnibox.inlineHost(prefix: typed, entries: session.omniboxEntries()) ?? ""
        ghostSuffix = Omnibox.completionSuffix(typed: typed, suggestion: host) ?? ""
        if SettingsStore.shared.addressAIGhost, !session.isPrivate, APIKeyStore.isSet, typed.count >= 2 {
            aiQuery = typed
        } else {
            aiQuery = ""
        }
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
        ghostSuffix = ""
        aiQuery = ""
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
    var ghostSuffix: String
    var focusToken: Int
    var onPrefix: (String) -> Void
    var onSubmit: (String) -> Void
    var onMove: (Int) -> Void
    var onEscape: () -> Void
    var onDismissGhost: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> GhostFieldView {
        let view = GhostFieldView()
        view.field.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: GhostFieldView, context: Context) {
        context.coordinator.parent = self
        if view.field.currentEditor() == nil, view.field.stringValue != prefix {
            view.field.stringValue = prefix
        }
        view.suffix = ghostSuffix
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view.field)
                view.field.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmniboxField
        weak var view: GhostFieldView?
        var applying = false
        var lastFocus = 0

        init(_ parent: OmniboxField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard !applying, let field = view?.field else { return }
            view?.renderGhost()
            parent.onPrefix(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let atEnd = caretAtEnd(textView, string: control.stringValue)
            let ghost = parent.ghostSuffix
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit(control.stringValue + (atEnd ? ghost : ""))
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
            if atEnd && !ghost.isEmpty && (commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.moveRight(_:))) {
                acceptGhost(control, textView: textView)
                return true
            }
            if atEnd && !ghost.isEmpty && commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                parent.onDismissGhost()
                return true
            }
            return false
        }

        private func acceptGhost(_ control: NSControl, textView: NSTextView) {
            let next = control.stringValue + parent.ghostSuffix
            applying = true
            control.stringValue = next
            textView.setSelectedRange(NSRange(location: (next as NSString).length, length: 0))
            applying = false
            view?.suffix = ""
            view?.renderGhost()
            parent.onPrefix(next)
        }

        private func caretAtEnd(_ textView: NSTextView, string: String) -> Bool {
            let selected = textView.selectedRange()
            return selected.length == 0 && selected.location == (string as NSString).length
        }
    }
}

final class GhostFieldView: NSView {
    let field = NSTextField(string: "")
    private let ghost = NSTextField(labelWithString: "")
    var suffix = "" {
        didSet { renderGhost() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.067, green: 0.071, blue: 0.082, alpha: 1).cgColor
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = NSColor(srgbRed: 0.89, green: 0.90, blue: 0.85, alpha: 1)
        field.lineBreakMode = .byTruncatingHead
        field.cell?.sendsActionOnEndEditing = false
        ghost.isBordered = false
        ghost.isBezeled = false
        ghost.drawsBackground = false
        ghost.isEditable = false
        ghost.isSelectable = false
        ghost.font = font
        ghost.lineBreakMode = .byClipping
        addSubview(ghost)
        addSubview(field)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.067, green: 0.071, blue: 0.082, alpha: 1).cgColor
        field.frame = bounds
        ghost.frame = bounds
    }

    func renderGhost() {
        let font = field.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let typed = field.stringValue
        guard !suffix.isEmpty else {
            ghost.attributedStringValue = NSAttributedString(string: "")
            return
        }
        let text = NSMutableAttributedString(string: typed, attributes: [
            .font: font,
            .foregroundColor: NSColor.clear
        ])
        text.append(NSAttributedString(string: suffix, attributes: [
            .font: font,
            .foregroundColor: NSColor(srgbRed: 0.55, green: 0.58, blue: 0.56, alpha: 0.9)
        ]))
        ghost.attributedStringValue = text
    }
}
