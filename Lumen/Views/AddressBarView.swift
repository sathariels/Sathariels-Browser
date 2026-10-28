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
    @ObservedObject private var downloads = DownloadController.shared
    @ObservedObject private var updates = AppUpdateCenter.shared
    @Environment(\.openSettings) private var openSettings
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
            HStack(spacing: 7) {
                HStack(spacing: 1) {
                    navButton("chevron.left", help: "Back", enabled: tab.canGoBack) { session.back() }
                    navButton("chevron.right", help: "Forward", enabled: tab.canGoForward) { session.forward() }
                    navButton(tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload", enabled: true) {
                        if tab.isLoading { tab.stop() } else { session.reloadFocused() }
                    }
                }
                navButton("sidebar.left", help: "Toggle sidebar", enabled: true) { session.grokVisible = false; session.sidebarVisible.toggle() }
                omnibox
                Menu {
                    Button("Sign in to Google…") {
                        session.newTab(url: URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.google.com%2Fai"))
                    }
                    Button("Google account…") { session.newTab(url: URL(string: "https://myaccount.google.com")) }
                    Divider()
                    Button("Browser settings…") { openSettings() }
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LumenTheme.profileText)
                        .frame(width: 27, height: 27)
                        .background(LumenTheme.profile)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Google account and settings")
                navButton("text.alignleft", help: "Reading mode", enabled: tab.webView != nil) { tab.toggleReader() }
                Button { session.downloadsVisible.toggle() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(downloads.hasActive ? LumenTheme.sky : LumenTheme.activeText)
                        Rectangle()
                            .fill(downloads.hasActive ? LumenTheme.sky : Color.clear)
                            .frame(width: 18 * (downloads.activeFraction ?? 0), height: 2)
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Downloads")
                if updates.showsButton {
                    Button { updates.showSheet = true } label: {
                        Text("Update")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(LumenTheme.activeText)
                            .frame(width: 64, height: 28)
                            .background(LumenTheme.omnibox)
                            .overlay(Rectangle().strokeBorder(LumenTheme.accent, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Install the latest version")
                }
                moreMenu
            }
            .padding(.horizontal, 9)
            .frame(height: 45)
            .background(LumenTheme.toolbar)
            .overlay(alignment: .bottom) {
                if tab.isLoading {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(LumenTheme.accent)
                            .frame(width: max(2, proxy.size.width * tab.progress), height: 2)
                    }
                    .frame(height: 2)
                } else {
                    Rectangle().fill(Color(red: 23 / 255, green: 27 / 255, blue: 24 / 255)).frame(height: 1)
                }
            }

            if !bookmarks.bookmarks.isEmpty { bookmarkBar }

            if showSite, let host = tab.url?.host {
                SitePermissionsEditor(host: host, store: session.permissions, onAutoplayChange: {
                    tab.suspend()
                    tab.wake()
                })
                .frame(maxWidth: 560, alignment: .leading)
                .background(LumenTheme.bgRaised)
                .overlay(Rectangle().strokeBorder(LumenTheme.sky, lineWidth: 1))
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
            if menuOpen && editing && !suggestions.isEmpty {
                suggestionList
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
        }
        .background(LumenTheme.bg)
        .onChange(of: session.addressFocusToken) { _, _ in
            editing = true
            showSite = false
        }
        .onChange(of: session.addressSeed) { _, seed in
            if let seed {
                prefix = seed
                ghostSuffix = ""
                dismissedPrefix = nil
                aiQuery = ""
                menuOpen = true
                editing = true
                session.addressSeed = nil
            }
        }
        .onChange(of: tab.url) { _, _ in
            if !editing { syncFromTab() }
        }
        .onChange(of: tab.id) { _, _ in
            editing = false
            showSite = false
            highlight = -1
            syncFromTab()
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
        HStack(spacing: 0) {
            Button {
                showSite.toggle()
                if showSite { menuOpen = false }
            } label: {
                Image(systemName: tab.url == nil ? "magnifyingglass" : (tab.url?.scheme == "https" ? "lock" : "magnifyingglass"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LumenTheme.omniboxMuted)
                    .frame(width: 22, height: 22)
                    .padding(.leading, 8)
            }
            .buttonStyle(.plain)
            .help("Site settings")
            .accessibilityLabel("Site settings")
            .disabled(tab.url?.host == nil)

            OmniboxField(
                prefix: $prefix,
                ghostSuffix: ghostSuffix,
                placeholder: "Search \(settings.searchEngine.label) or type a URL",
                focusToken: session.addressFocusToken,
                onPrefix: { typed in
                    prefix = typed
                    editing = true
                    showSite = false
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
                    menuOpen = true
                    editing = true
                    if highlight < 0 { highlight = 0 } else { highlight = (highlight + delta + count) % count }
                },
                onEscape: {
                    menuOpen = false
                    editing = false
                    ghostSuffix = ""
                    aiQuery = ""
                    dismissedPrefix = nil
                    showSite = false
                    let restored = tab.url?.absoluteString ?? ""
                    prefix = restored
                    return restored
                },
                onDismissGhost: {
                    dismissedPrefix = prefix
                    ghostSuffix = ""
                    aiQuery = ""
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .id(tab.id)

            Button {
                guard let url = tab.url else { return }
                bookmarks.toggle(url: url, title: tab.title)
            } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isBookmarked ? LumenTheme.accent : LumenTheme.omniboxMuted)
                    .frame(width: 22, height: 22)
                    .padding(.trailing, 8)
            }
            .buttonStyle(.plain)
            .help("Bookmark this page")
        }
        .frame(height: 34)
        .background(editing ? LumenTheme.field : LumenTheme.omnibox)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(editing ? LumenTheme.omniboxFocus : LumenTheme.omniboxBorder, lineWidth: 1))
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
                            .font(.system(size: 13))
                            .foregroundStyle(LumenTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.kind == .search ? "Search \(settings.searchEngine.label)" : row.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(LumenTheme.textDim)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == highlight ? LumenTheme.toolbar : LumenTheme.omnibox)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { highlight = index }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumenTheme.omnibox)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LumenTheme.omniboxBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
    }

    private var moreMenu: some View {
        Menu {
            Button("Find") { session.showFind() }
            Button("Downloads") { session.downloadsVisible.toggle() }
            Divider()
            Button("Split View") { session.toggleSplit() }
            Button("Swap Split") { session.swapSplit() }
            Button("Close Split") { session.closeSplit() }
            Divider()
            Button("Inspect Element") { session.showInspector() }
            Button(session.viewportOpen ? "Hide Responsive Size" : "Responsive Size") { session.viewportOpen.toggle() }
            Button(session.grokVisible ? "Hide Grok" : "Grok") { session.toggleGrok() }
            Button("Library") {
                session.upperPane = .bookmarks
                session.sidebarVisible = true
            }
            Divider()
            Button("Settings…") { openSettings() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LumenTheme.activeText)
                .frame(width: 33, height: 33)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
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
        guard let url = AddressResolver.resolve(trimmed, engine: settings.searchEngine, shortcuts: settings.keywordShortcuts) else { return }
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
        showSite = false
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
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(enabled ? LumenTheme.activeText : LumenTheme.omniboxMuted)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.32)
        .help(help)
    }

    private var bookmarkBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
            ForEach(bookmarks.bookmarks.prefix(12)) { mark in
                bookmarkChip(nil, title: mark.title) { open(urlString: mark.url) }
            }
            Spacer(minLength: 8)
            bookmarkChip("folder", title: "All bookmarks") { openLibrary() }
        }
        .padding(.horizontal, 14)
        }
        .frame(height: 31)
        .background(LumenTheme.bookmarkBar)
        .overlay(alignment: .bottom) { Rectangle().fill(LumenTheme.ink.opacity(0.12)).frame(height: 1) }
    }

    private func openLibrary() {
        session.upperPane = .bookmarks
        session.sidebarVisible = true
    }

    private func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        session.navigateFocused(to: url)
    }

    private func bookmarkChip(_ symbol: String?, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(LumenTheme.bookmarkText)
            .padding(.horizontal, 8)
            .frame(height: 23)
        }
        .buttonStyle(.plain)
    }

}

struct OmniboxField: NSViewRepresentable {
    @Binding var prefix: String
    var ghostSuffix: String
    var placeholder: String
    var focusToken: Int
    var onPrefix: (String) -> Void
    var onSubmit: (String) -> Void
    var onMove: (Int) -> Void
    var onEscape: () -> String
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
        view.field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: GhostFieldView.font,
                .foregroundColor: NSColor(srgbRed: 152 / 255, green: 163 / 255, blue: 156 / 255, alpha: 1)
            ]
        )
        if view.field.stringValue != prefix {
            view.field.stringValue = prefix
            if let editor = view.field.currentEditor() as? NSTextView {
                editor.string = prefix
                editor.setSelectedRange(NSRange(location: (prefix as NSString).length, length: 0))
            }
        }
        view.suffix = ghostSuffix
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async {
                view.focusForCommand()
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmniboxField
        weak var view: GhostFieldView?
        var applying = false
        var submitting = false
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
                submitting = true
                parent.onSubmit(control.stringValue + (atEnd ? ghost : ""))
                control.abortEditing()
                view?.window?.makeFirstResponder(nil)
                submitting = false
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                let restored = parent.onEscape()
                applying = true
                control.stringValue = restored
                textView.string = restored
                textView.setSelectedRange(NSRange(location: 0, length: (restored as NSString).length))
                applying = false
                view?.suffix = ""
                view?.renderGhost()
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
            textView.string = next
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

/// Editable address field with ghost text drawn behind it.
/// The ghost used to be a second NSTextField on the same rect. It won hit testing,
/// so the real field never became first responder and keystrokes went nowhere.
final class GhostFieldView: NSView {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let field = OmniboxTextField(string: "")
    private let ghost = NSTextField(labelWithString: "")
    var suffix = "" {
        didSet { renderGhost() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.refusesFirstResponder = false
        field.focusRingType = .none
        field.font = Self.font
        field.textColor = NSColor(srgbRed: 225 / 255, green: 231 / 255, blue: 227 / 255, alpha: 1)
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = false
        field.setAccessibilityLabel("Address and search")
        ghost.isBordered = false
        ghost.isBezeled = false
        ghost.drawsBackground = false
        ghost.isEditable = false
        ghost.isSelectable = false
        ghost.isEnabled = false
        ghost.font = Self.font
        ghost.lineBreakMode = .byClipping
        field.autoresizingMask = [.width, .height]
        ghost.autoresizingMask = [.width, .height]
        addSubview(ghost)
        addSubview(field)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? field : nil
    }

    override func mouseDown(with event: NSEvent) {
        field.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        fitFields()
    }

    private func fitFields() {
        let rect = NSRect(x: 0, y: max(0, (bounds.height - 18) / 2), width: bounds.width, height: 18)
        field.frame = rect
        ghost.frame = rect
    }

    func focusForCommand() {
        NSApp.activate()
        guard let window else { return }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func renderGhost() {
        let font = field.font ?? Self.font
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

final class OmniboxTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let editor = currentEditor()
        let alreadyEditing = editor != nil && window?.firstResponder === editor
        if !alreadyEditing {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}

final class PassHitView: NSView {
    var onMove: (() -> Void)?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didExitFullScreenNotification, object: window)
        onMove?()
    }

    @objc private func moved() { onMove?() }
}
