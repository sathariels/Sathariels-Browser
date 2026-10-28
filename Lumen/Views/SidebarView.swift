import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            paneSwitcher
            upper
            Rectangle().fill(LumenTheme.teal.opacity(0.8)).frame(height: 1)
            SectionLabel(title: "Clipboard", color: LumenTheme.teal)
            clipboardList
                .frame(height: session.clipboardHeight)
            footer
        }
        .background(LumenTheme.bgRaised)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(session.isPrivate ? LumenTheme.coral : LumenTheme.amber)
                .frame(width: 10, height: 10)
            Text(session.isPrivate ? "PRIVATE" : "LUMEN")
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
            switcher("Marks", .bookmarks, LumenTheme.lime)
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
        VStack(alignment: .leading, spacing: 6) {
            Button("Grok Bot") { session.openGrokBot(sendPage: false) }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.violet))
            Button("Send page to bot") { session.openGrokBot(sendPage: true) }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.teal))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.vertical, 4)
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
        .padding(.vertical, 4)
        .background(active ? color.opacity(0.16) : Color.clear)
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
