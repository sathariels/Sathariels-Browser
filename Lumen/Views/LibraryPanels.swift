import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @State private var query = ""
    var onClose: () -> Void

    private var historyRows: [HistoryEntry] {
        session.isPrivate ? [] : history.search(query, limit: 40)
    }

    private var bookmarkRows: [Bookmark] {
        bookmarks.search(query, limit: 20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("LIBRARY")
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.accent)
                TextField("Search history and bookmarks", text: $query)
                    .textFieldStyle(.plain)
                    .font(LumenTheme.mono)
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LumenTheme.textDim)
            }
            .padding(10)
            Rectangle().fill(LumenTheme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SectionLabel(title: "Bookmarks", color: LumenTheme.accent)
                    if bookmarkRows.isEmpty {
                        note("No bookmarks match.")
                    }
                    ForEach(bookmarkRows) { mark in
                        row(title: mark.title, subtitle: mark.host, color: LumenTheme.accent) {
                            open(mark.url)
                        } onDelete: { bookmarks.delete(mark.id) }
                    }
                    SectionLabel(title: "History", color: LumenTheme.accent)
                    if session.isPrivate {
                        note("Private windows do not record visits.")
                    } else if historyRows.isEmpty {
                        note("Pages you visit show up here.")
                    }
                    ForEach(historyRows) { entry in
                        row(title: entry.title, subtitle: entry.host, color: LumenTheme.accent) {
                            open(entry.url)
                        } onDelete: { history.delete(entry.id) }
                    }
                    if !session.isPrivate && !history.entries.isEmpty && query.isEmpty {
                        Button("Clear history") { history.clear() }
                            .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
                            .padding(8)
                    }
                }
            }
        }
        .frame(width: 420, height: 460)
        .background(LumenTheme.bgRaised)
        .onExitCommand(perform: onClose)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        session.navigateFocused(to: url)
        onClose()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(LumenTheme.monoSmall)
            .foregroundStyle(LumenTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    private func row(title: String, subtitle: String, color: Color, open: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
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
        .padding(.vertical, 6)
    }
}

struct CommandPanel: View {
    @ObservedObject var session: BrowserSession
    @FocusState private var focused: Bool

    private var hits: [CommandHit] {
        CommandSearch.results(
            query: session.commandQuery,
            tabs: session.tabs.map { ($0.id, $0.title, $0.url?.absoluteString ?? "") },
            bookmarks: BookmarkStore.shared.search(session.commandQuery, limit: 6),
            history: session.isPrivate ? [] : HistoryStore.shared.search(session.commandQuery, limit: 6)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Rectangle().fill(LumenTheme.accent).frame(width: 8, height: 8)
                TextField("Search tabs, bookmarks, history", text: $session.commandQuery)
                    .textFieldStyle(.plain)
                    .font(LumenTheme.mono)
                    .focused($focused)
                    .onSubmit { activate(hits.first) }
            }
            .padding(10)
            Rectangle().fill(LumenTheme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hits.isEmpty {
                        Text("Nothing matches.")
                            .font(LumenTheme.monoSmall)
                            .foregroundStyle(LumenTheme.textDim)
                            .padding(10)
                    }
                    ForEach(hits) { hit in
                        Button { activate(hit) } label: {
                            HStack(spacing: 8) {
                                Text(label(hit.kind))
                                    .font(LumenTheme.micro)
                                    .foregroundStyle(LumenTheme.accent)
                                    .frame(width: 72, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(hit.title).font(LumenTheme.monoSmall).foregroundStyle(LumenTheme.text).lineLimit(1)
                                    Text(hit.subtitle).font(LumenTheme.micro).foregroundStyle(LumenTheme.textDim).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 520)
        .background(LumenTheme.bgRaised)
        .overlay(Rectangle().strokeBorder(LumenTheme.accent, lineWidth: 1))
        .onAppear { focused = true }
        .onExitCommand { session.commandVisible = false }
    }

    private func label(_ kind: CommandHit.Kind) -> String {
        switch kind {
        case .tab: return "TAB"
        case .bookmark: return "SAVED"
        case .history: return "HISTORY"
        }
    }

    private func activate(_ hit: CommandHit?) {
        guard let hit else { return }
        if let tabID = hit.tabID {
            session.select(tabID)
        } else if let url = hit.url.flatMap(URL.init(string:)) {
            session.navigateFocused(to: url)
        }
        session.commandVisible = false
    }
}

struct MemoryPanel: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var loads = TabLoadCenter.shared
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MEMORY")
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.accent)
                Spacer()
                Text("\(loads.processCount) WebContent · \(MemoryFormat.megabytes(loads.totalBytes))")
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.textDim)
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LumenTheme.textDim)
            }
            .padding(10)
            Rectangle().fill(LumenTheme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(loads.rows) { row in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(LumenTheme.monoSmall).foregroundStyle(LumenTheme.text).lineLimit(1)
                                Text(detail(row))
                                    .font(LumenTheme.micro)
                                    .foregroundStyle(LumenTheme.textDim)
                            }
                            Spacer(minLength: 4)
                            if !row.asleep {
                                Button("Sleep") { session.sleepTab(row.id) }
                                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.accent, accent: true))
                            }
                            Button("Close") { session.closeTab(row.id) }
                                .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
            }
            Text("Sampled only while this panel is open. Process RSS is shown when each live tab has its own WebContent process.")
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.textDim)
                .padding(10)
        }
        .frame(width: 440, height: 420)
        .background(LumenTheme.bgRaised)
        .onAppear { TabLoadCenter.shared.start(session) }
        .onDisappear { TabLoadCenter.shared.stop() }
        .onExitCommand(perform: onClose)
    }

    private func detail(_ row: TabLoadRow) -> String {
        if row.asleep { return "asleep" }
        let size = row.measured ? MemoryFormat.megabytes(row.bytes) : "~\(MemoryFormat.megabytes(row.bytes))"
        let energy = row.measured ? " · \(EnergyEstimate.label(row.cpu)) \(Int((row.cpu * 100).rounded()))% CPU" : ""
        return size + energy
    }
}
