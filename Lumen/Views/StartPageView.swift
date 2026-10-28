import SwiftUI

struct StartPageView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 6) {
                    Rectangle().fill(LumenTheme.amber).frame(width: 14, height: 14)
                    Rectangle().fill(LumenTheme.teal).frame(width: 14, height: 14)
                    Rectangle().fill(LumenTheme.violet).frame(width: 14, height: 14)
                    Text(session.isPrivate ? "PRIVATE" : "SATHARIELS")
                        .font(LumenTheme.micro)
                        .tracking(1.6)
                        .foregroundStyle(session.isPrivate ? LumenTheme.coral : LumenTheme.amber)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(LumenTheme.textDim)
                    TextField("Search \(settings.searchEngine.label) or type a URL", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .foregroundStyle(LumenTheme.text)
                        .focused($focused)
                        .onSubmit { go() }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(LumenTheme.field)
                .overlay(Rectangle().strokeBorder(focused ? LumenTheme.amber : LumenTheme.border, lineWidth: 1))

                if session.isPrivate {
                    Text("This window does not write history, passwords, or the session file.")
                        .font(.system(size: 12))
                        .foregroundStyle(LumenTheme.coral)
                }

                if !bookmarks.bookmarks.isEmpty {
                    Text("BOOKMARKS")
                        .font(LumenTheme.micro)
                        .foregroundStyle(LumenTheme.lime)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(bookmarks.bookmarks.prefix(8)) { mark in
                            Button {
                                open(mark.url)
                            } label: {
                                HStack(spacing: 6) {
                                    Rectangle().fill(LumenTheme.lime).frame(width: 8, height: 8)
                                    Text(mark.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(LumenTheme.text)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 32)
                                .background(LumenTheme.bgRaised)
                                .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !session.isPrivate && !history.entries.isEmpty {
                    Text("RECENT")
                        .font(LumenTheme.micro)
                        .foregroundStyle(LumenTheme.sky)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(history.entries.sorted { $0.lastVisit > $1.lastVisit }.prefix(8)) { entry in
                            Button {
                                open(entry.url)
                            } label: {
                                HStack(spacing: 6) {
                                    Rectangle().fill(LumenTheme.sky).frame(width: 8, height: 8)
                                    Text(entry.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(LumenTheme.text)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 32)
                                .background(LumenTheme.bgRaised)
                                .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 584)
            .padding(.horizontal, 24)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func go() {
        guard let url = AddressResolver.resolve(query, engine: settings.searchEngine, shortcuts: settings.keywordShortcuts) else { return }
        session.select(tab.id)
        session.navigateFocused(to: url)
    }

    private func open(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        session.select(tab.id)
        session.navigateFocused(to: url)
    }
}
