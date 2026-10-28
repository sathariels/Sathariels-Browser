import AppKit
import SwiftUI

struct SidebarView: View {
    @AppStorage("settingsSection") private var settingsSection = "General"
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var session: BrowserSession
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            if !session.clipboardOnly {
                paneSwitcher
                upper
            }
            Rectangle().fill(LumenTheme.border).frame(height: 1)
            SectionLabel(title: "Clipboard", color: LumenTheme.teal)
            clipboardList
                .frame(minHeight: 120, maxHeight: session.clipboardOnly ? .infinity : session.clipboardHeight)
            footer
        }
        .background(LumenTheme.bgRaised)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(session.isPrivate ? LumenTheme.coral : LumenTheme.amber)
                .frame(width: 10, height: 10)
            Text(session.isPrivate ? "PRIVATE" : "SATHARIELS")
                .font(LumenTheme.micro)
                .tracking(1.6)
                .foregroundStyle(session.isPrivate ? LumenTheme.coral : LumenTheme.amber)
            Spacer()
        }
        .padding(8)
    }

    private var paneSwitcher: some View {
        HStack(spacing: 4) {
            switcher("Tabs", .tabs, LumenTheme.amber)
            switcher("Saved", .bookmarks, LumenTheme.lime)
            switcher("History", .history, LumenTheme.sky)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var upper: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch session.upperPane {
                case .tabs:
                    ForEach(session.tabs) { tab in
                        TabRow(session: session, tab: tab)
                    }
                    Button("New tab") { session.newTab() }
                        .buttonStyle(LumenButtonStyle(tint: LumenTheme.amber))
                        .padding(8)
                    LocalhostSection(session: session)
                case .bookmarks:
                    if bookmarks.bookmarks.isEmpty {
                        emptyLine("No bookmarks yet. Star a page to keep it.")
                    }
                    ForEach(bookmarks.bookmarks) { mark in
                        libraryRow(title: mark.title, subtitle: mark.host, color: LumenTheme.lime) {
                            if let url = URL(string: mark.url) { session.navigateFocused(to: url) }
                        } onDelete: { bookmarks.delete(mark.id) }
                    }
                case .history:
                    if session.isPrivate {
                        emptyLine("Private windows do not record visits.")
                    } else if history.entries.isEmpty {
                        emptyLine("Pages you visit show up here.")
                    } else {
                        ForEach(history.entries.prefix(200)) { entry in
                            libraryRow(title: entry.title, subtitle: entry.host, color: LumenTheme.sky) {
                                if let url = URL(string: entry.url) { session.navigateFocused(to: url) }
                            } onDelete: { history.delete(entry.id) }
                        }
                        Button("Clear history") { history.clear() }
                            .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
                            .padding(8)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var clipboardList: some View {
        VStack(spacing: 0) {
            if !settings.clipboardCapture {
                emptyLine("Clipboard capture is paused.")
            } else if session.isPrivate && session.isKey {
                emptyLine("Paused while this private window is active.")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if clipboard.items.isEmpty { emptyLine("Copied text and links appear here. Pin what you want to keep.") }
                    ForEach(clipboard.items) { item in
                        ClipboardRow(item: item, session: session)
                    }
                }
            }
            HStack(spacing: 6) {
                Button(settings.clipboardCapture ? "Pause" : "Resume") {
                    settings.clipboardCapture.toggle()
                }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.teal))
                Button("Clear") { clipboard.clearUnpinned() }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
                Spacer()
            }
            .padding(8)
        }
    }

    private var footer: some View {
        HStack {
            Button { openSettings() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
            Spacer()
            Button { session.openGrokBot(sendPage: false) } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open Grok Bot")
        }
        .buttonStyle(.plain)
        .font(LumenTheme.monoSmall)
        .foregroundStyle(LumenTheme.textDim)
        .padding(12)
    }

    private func switcher(_ title: String, _ pane: UpperPane, _ color: Color) -> some View {
        Button(title) { session.upperPane = pane }
            .buttonStyle(LumenButtonStyle(tint: session.upperPane == pane ? color : LumenTheme.textDim))
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(LumenTheme.monoSmall)
            .foregroundStyle(LumenTheme.textDim)
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func libraryRow(title: String, subtitle: String, color: Color, open: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 8, height: 8)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(LumenTheme.monoSmall).foregroundStyle(LumenTheme.text).lineLimit(1)
                    Text(subtitle).font(LumenTheme.micro).foregroundStyle(LumenTheme.textDim).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "xmark").foregroundStyle(LumenTheme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}

struct LocalhostSection: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var settings = SettingsStore.shared
    @State private var open = false
    @StateObject private var model = LocalhostModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(open ? "Local −" : "Local +") { open.toggle() }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.lime))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            if open {
                Text(model.status)
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.textDim)
                    .padding(.horizontal, 8)
                ForEach(model.ports, id: \.self) { port in
                    Button("127.0.0.1:\(port)") {
                        if let url = URL(string: "http://127.0.0.1:\(port)") {
                            session.navigateFocused(to: url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(LumenTheme.monoSmall)
                    .foregroundStyle(LumenTheme.lime)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
                HStack(spacing: 6) {
                    Button(model.scanning ? "…" : "Scan") { model.scan() }
                        .buttonStyle(LumenButtonStyle(tint: LumenTheme.lime))
                        .disabled(model.scanning)
                    Toggle(isOn: $settings.localhostAutoReload) {
                        Text("Reload")
                            .font(LumenTheme.micro)
                            .foregroundStyle(LumenTheme.lime)
                    }
                    .toggleStyle(.checkbox)
                    .help("Reload the focused localhost tab when the server restarts. Off by default.")
                }
                .padding(8)
            }
        }
    }
}

struct TabRow: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab

    var body: some View {
        let active = session.focusedTab?.id == tab.id
        let color = LumenTheme.tabColor(tab.colorIndex)
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: active ? 3 : 3, height: 18)
            if let image = tab.favicon {
                Image(nsImage: image).resizable().frame(width: 12, height: 12)
            } else {
                Text(letter)
                    .font(LumenTheme.micro)
                    .foregroundStyle(color)
                    .frame(width: 12)
            }
            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(MemoryFormat.badge(bytes: tab.memory.bytes, kind: tab.memory.kind))
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.textDim)
            Button {
                session.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").foregroundStyle(LumenTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(active ? LumenTheme.accent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { session.select(tab.id) }
        .contextMenu {
            Button("Open in Split") { session.openInSplit(tab.id) }
            Button("Reload") { session.select(tab.id); session.reloadFocused() }
            Button("Copy URL") {
                if let url = tab.url?.absoluteString {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
            Menu("Color") {
                ForEach(0..<LumenTheme.tabPalette.count, id: \.self) { index in
                    Button("Tag \(index + 1)") { tab.colorIndex = index }
                }
            }
            Button("Close") { session.closeTab(tab.id) }
        }
        .help(tab.memory.kind == .estimate ? "Estimated from page resources, not process RSS." : "Tab memory")
    }

    private var letter: String {
        let host = tab.url?.host ?? tab.title
        return String(host.prefix(1)).uppercased()
    }
}

struct ClipboardRow: View {
    let item: ClipItem
    @ObservedObject var session: BrowserSession
    @ObservedObject private var store = ClipboardStore.shared
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(item.kind == .url ? LumenTheme.sky : LumenTheme.teal)
                .frame(width: 8, height: 8)
            if let thumb {
                Image(nsImage: thumb).resizable().frame(width: 16, height: 16)
            }
            Text(item.text ?? "Image")
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { store.togglePin(item.id) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(item.pinned ? LumenTheme.amber : LumenTheme.textDim)
            }
            .buttonStyle(.plain)
            .help(item.pinned ? "Unpin" : "Pin")
            if item.kind != .image {
                Button("Paste") {
                    session.paste(text: item.text ?? "", intoAddress: NSApp.keyWindow?.firstResponder is NSTextView)
                }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.teal))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { store.copy(item) }
        .onAppear { thumb = store.thumbnail(for: item) }
        .onDisappear { thumb = nil }
        .contextMenu {
            Button("Copy") { store.copy(item) }
            if item.kind == .url, let text = item.text, let url = URL(string: text) {
                Button("Open") { session.navigateFocused(to: url) }
            }
            Button("Delete") { store.delete(item.id) }
        }
    }
}


struct BrowserRail: View {
    @ObservedObject var session: BrowserSession
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            railButton("sparkles", "AI assistant", active: session.grokVisible) { session.toggleGrok() }
            railButton("rectangle.on.rectangle", "Tabs and library", active: session.sidebarVisible && !session.grokVisible && !session.clipboardOnly) {
                let wasTabs = session.sidebarVisible && !session.grokVisible && !session.clipboardOnly
                session.grokVisible = false
                session.clipboardOnly = false
                session.sidebarVisible = !wasTabs
            }
            railButton("doc.on.clipboard", "Clipboard history", active: session.sidebarVisible && !session.grokVisible && session.clipboardOnly) {
                let wasClipboard = session.sidebarVisible && !session.grokVisible && session.clipboardOnly
                session.grokVisible = false
                session.clipboardOnly = true
                session.sidebarVisible = !wasClipboard
            }
            railButton("globe", "Google AI Mode", active: false) {
                session.newTab(url: URL(string: "https://www.google.com/ai"))
            }
            railButton("xmark", "X · x.com", active: false) {
                session.newTab(url: URL(string: "https://x.com"))
            }
            railButton("graduationcap", "Canvas · University of Wisconsin", active: false) {
                session.newTab(url: URL(string: "https://canvas.wisc.edu/"))
            }
            Spacer(minLength: 12)
            railButton("gearshape", "Settings", active: false) { openSettings() }
        }
        .padding(.vertical, 12)
        .frame(width: 48)
        .frame(maxHeight: .infinity)
        .background(LumenTheme.bg)
        .overlay(alignment: .trailing) { Rectangle().fill(LumenTheme.border).frame(width: 1) }
    }

    private func railButton(_ icon: String, _ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(active ? LumenTheme.text : LumenTheme.textDim)
                .frame(width: 36, height: 36)
                .background(active ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
