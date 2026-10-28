import SwiftUI

struct StartPageView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(session.isPrivate ? LumenTheme.coral : LumenTheme.amber)
                        .frame(width: 14, height: 14)
                    Text(session.isPrivate ? "PRIVATE TAB" : "LUMEN")
                        .font(LumenTheme.micro)
                        .tracking(2)
                        .foregroundStyle(session.isPrivate ? LumenTheme.coral : LumenTheme.amber)
                }
                Text(session.isPrivate ? "Nothing from this window is written to history." : "Search or type an address.")
                    .font(LumenTheme.title)
                    .foregroundStyle(LumenTheme.text)
                if !bookmarks.bookmarks.isEmpty {
                    SectionLabel(title: "Bookmarks", color: LumenTheme.lime)
                    ForEach(bookmarks.bookmarks.prefix(8)) { mark in
                        Button {
                            session.select(tab.id)
                            if let url = URL(string: mark.url) { session.navigateFocused(to: url) }
                        } label: {
                            HStack {
                                Rectangle().fill(LumenTheme.lime).frame(width: 8, height: 8)
                                Text(mark.title).font(LumenTheme.monoSmall).foregroundStyle(LumenTheme.text).lineLimit(1)
                                Spacer()
                                Text(mark.host).font(LumenTheme.micro).foregroundStyle(LumenTheme.textDim)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !session.isPrivate && !history.entries.isEmpty {
                    SectionLabel(title: "Recent", color: LumenTheme.sky)
                    ForEach(history.entries.sorted { $0.lastVisit > $1.lastVisit }.prefix(8)) { entry in
                        Button {
                            session.select(tab.id)
                            if let url = URL(string: entry.url) { session.navigateFocused(to: url) }
                        } label: {
                            HStack {
                                Rectangle().fill(LumenTheme.sky).frame(width: 8, height: 8)
                                Text(entry.title).font(LumenTheme.monoSmall).foregroundStyle(LumenTheme.text).lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
