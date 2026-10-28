import AppKit
import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var session: BrowserSession
    @State private var sidebarOrigin: Double?
    @State private var grokOrigin: Double?
    @State private var splitOrigin: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            if session.isPrivate {
                Rectangle().fill(LumenTheme.coral).frame(height: 3)
                Text("PRIVATE  ·  not saved to history")
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.coral)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(LumenTheme.bg)
            }
            HStack(spacing: 0) {
                if session.sidebarVisible {
                    SidebarView(session: session)
                        .frame(width: session.sidebarWidth)
                    dragHandle(width: true)
                }
                VStack(spacing: 0) {
                    AddressBarHost(session: session)
                    if session.viewportOpen, let tab = session.focusedTab {
                        ViewportBar(tab: tab)
                    }
                    if session.findVisible { FindBar(session: session) }
                    BannerHost(session: session)
                    split
                    if session.downloadsVisible {
                        DownloadsPanel()
                            .frame(height: 160)
                    }
                    StatusBar(session: session)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if session.grokVisible, let chat = session.chatStore {
                    dragHandle(width: false)
                    GrokPanel(session: session, chat: chat)
                        .frame(width: session.grokWidth)
                }
            }
        }
        .background(LumenTheme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 860, minHeight: 520)
        .background(KeyWindowProbe(session: session))
        .alert("Grok Bot", isPresented: Binding(
            get: { session.botNotice != nil },
            set: { if !$0 { session.botNotice = nil } }
        )) {
            Button("OK", role: .cancel) { session.botNotice = nil }
        } message: {
            Text(session.botNotice ?? "")
        }
    }

    private func dragHandle(width: Bool) -> some View {
        Rectangle()
            .fill(LumenTheme.border)
            .frame(width: 4)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if width {
                            if sidebarOrigin == nil { sidebarOrigin = session.sidebarWidth }
                            session.sidebarWidth = min(420, max(200, (sidebarOrigin ?? 248) + value.translation.width))
                        } else {
                            if grokOrigin == nil { grokOrigin = session.grokWidth }
                            session.grokWidth = min(520, max(260, (grokOrigin ?? 320) - value.translation.width))
                        }
                    }
                    .onEnded { _ in
                        sidebarOrigin = nil
                        grokOrigin = nil
                        session.persist()
                    }
            )
    }

    private var split: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                pane(.primary)
                    .frame(width: session.isSplit ? geo.size.width * session.splitFraction : nil)
                if session.isSplit {
                    Rectangle()
                        .fill(LumenTheme.border)
                        .frame(width: 4)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    if splitOrigin == nil { splitOrigin = session.splitFraction }
                                    let next = (splitOrigin ?? 0.5) + (value.translation.width / max(geo.size.width, 1))
                                    session.splitFraction = min(0.75, max(0.25, next))
                                }
                                .onEnded { _ in
                                    splitOrigin = nil
                                    session.persist()
                                }
                        )
                    pane(.secondary)
                }
            }
        }
    }

    private func pane(_ pane: Pane) -> some View {
        let id = pane == .primary ? session.primaryTabID : session.secondaryTabID
        return ZStack(alignment: .topLeading) {
            LumenTheme.bg
            if let tab = session.tab(id) {
                PaneContent(session: session, tab: tab)
            }
            Rectangle()
                .fill(session.focusedPane == pane ? LumenTheme.tabColor(session.tab(id)?.colorIndex ?? 0) : Color.clear)
                .frame(height: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { session.focus(pane) }
    }
}

struct BannerHost: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        if let tab = session.focusedTab {
            BannerStack(session: session, tab: tab)
        }
    }
}

struct BannerStack: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab

    var body: some View {
        VStack(spacing: 0) {
            if tab.googleBlocked {
                banner(color: LumenTheme.coral, text: "Google blocked this sign-in inside the web view.") {
                    Button("Secure session") {
                        let url = tab.url ?? URL(string: "https://accounts.google.com")!
                        GoogleSignInCoordinator.shared.start(url: url)
                    }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
                }
            }
            if !tab.passwordUsernames.isEmpty {
                banner(color: LumenTheme.lime, text: "Keychain login for \(tab.passwordUsernames.joined(separator: ", "))") {
                    ForEach(tab.passwordUsernames.prefix(3), id: \.self) { name in
                        Button(name) { tab.fillPassword(username: name) }
                            .buttonStyle(LumenButtonStyle(tint: LumenTheme.lime))
                    }
                }
            }
            if let error = tab.errorText, !tab.isLoading {
                banner(color: LumenTheme.coral, text: error) {
                    Button("Retry") { session.reloadFocused() }
                        .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
                }
            }
        }
    }

    private func banner<Extra: View>(color: Color, text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.text)
                .lineLimit(2)
            Spacer(minLength: 8)
            extra()
        }
        .padding(6)
        .background(LumenTheme.bgRaised)
        .overlay(Rectangle().strokeBorder(color.opacity(0.8), lineWidth: 1))
    }
}

struct PaneContent: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab

    var body: some View {
        Group {
            if let document = tab.jsonDocument {
                JSONTreeView(tab: tab, document: document)
            } else if let webView = tab.webView {
                viewportFrame(webView: webView)
            } else if tab.url == nil {
                StartPageView(session: session, tab: tab)
            } else {
                VStack(spacing: 8) {
                    Text(tab.title)
                        .font(LumenTheme.title)
                        .foregroundStyle(LumenTheme.text)
                    Text(tab.url?.host ?? "")
                        .font(LumenTheme.monoSmall)
                        .foregroundStyle(LumenTheme.textDim)
                    Text("Asleep")
                        .font(LumenTheme.micro)
                        .foregroundStyle(LumenTheme.amber)
                    Button("Wake") { session.select(tab.id) }
                        .buttonStyle(LumenButtonStyle(tint: LumenTheme.amber))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func viewportFrame(webView: WKWebView) -> some View {
        if let size = tab.viewport.size {
            ZStack {
                LumenTheme.bg
                WebViewRepresentable(webView: webView)
                    .id(ObjectIdentifier(webView))
                    .frame(width: size.width, height: size.height)
                    .overlay(Rectangle().strokeBorder(LumenTheme.sky, lineWidth: 1))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WebViewRepresentable(webView: webView)
                .id(ObjectIdentifier(webView))
        }
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview !== nsView {
            webView.removeFromSuperview()
            webView.frame = nsView.bounds
            webView.autoresizingMask = [.width, .height]
            nsView.addSubview(webView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}

struct KeyWindowProbe: NSViewRepresentable {
    @ObservedObject var session: BrowserSession

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.session = session
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.session = session
        nsView.window?.title = session.isPrivate ? "Private — Sathariels Browser" : (session.focusedTab?.title ?? "Sathariels Browser")
        nsView.window?.backgroundColor = LumenTheme.windowBackground
        nsView.window?.appearance = NSAppearance(named: .darkAqua)
    }

    final class ProbeView: NSView {
        weak var session: BrowserSession?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(willClose), name: NSWindow.willCloseNotification, object: window)
            keyChanged()
        }
        @objc private func keyChanged() {
            session?.isKey = window?.isKeyWindow ?? false
        }
        @objc private func willClose() {
            session?.shutdown()
        }
    }
}

struct ViewportBar: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ViewportMode.Preset.allCases) { preset in
                Button(preset.label) {
                    var mode = tab.viewport
                    mode.preset = preset
                    tab.applyViewport(mode)
                }
                .buttonStyle(LumenButtonStyle(tint: tab.viewport.preset == preset ? LumenTheme.sky : LumenTheme.textDim))
            }
            if tab.viewport.preset == .custom {
                TextField("W", value: Binding(
                    get: { tab.viewport.customWidth },
                    set: { value in
                        var mode = tab.viewport
                        mode.customWidth = min(2000, max(200, value))
                        tab.applyViewport(mode)
                    }
                ), format: .number)
                .textFieldStyle(.plain)
                .font(LumenTheme.monoSmall)
                .frame(width: 48)
                TextField("H", value: Binding(
                    get: { tab.viewport.customHeight },
                    set: { value in
                        var mode = tab.viewport
                        mode.customHeight = min(2000, max(200, value))
                        tab.applyViewport(mode)
                    }
                ), format: .number)
                .textFieldStyle(.plain)
                .font(LumenTheme.monoSmall)
                .frame(width: 48)
            }
            Toggle(isOn: Binding(
                get: { tab.viewport.mobileUserAgent },
                set: { value in
                    var mode = tab.viewport
                    mode.mobileUserAgent = value
                    tab.applyViewport(mode)
                }
            )) {
                Text("Mobile UA")
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.sky)
            }
            .toggleStyle(.checkbox)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(LumenTheme.bgRaised)
    }
}

struct FindBar: View {
    @ObservedObject var session: BrowserSession
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("FIND")
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.amber)
            TextField("Find", text: $session.findQuery)
                .textFieldStyle(.plain)
                .font(LumenTheme.mono)
                .foregroundStyle(LumenTheme.text)
                .focused($focused)
                .onSubmit { session.findStep(forward: true) }
                .onChange(of: session.findQuery) { _, _ in session.updateFind(reset: true) }
            Text(session.findCount == 0 ? "0" : "\(session.findIndex + 1)/\(session.findCount)")
                .font(LumenTheme.micro)
                .foregroundStyle(LumenTheme.textDim)
            Button("Prev") { session.findStep(forward: false) }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.amber))
            Button("Next") { session.findStep(forward: true) }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.amber))
            Button("Close") { session.closeFind() }
                .buttonStyle(LumenButtonStyle(tint: LumenTheme.textDim))
        }
        .padding(6)
        .background(LumenTheme.bgRaised)
        .onChange(of: session.findFocusToken) { _, _ in focused = true }
    }
}

struct DownloadsPanel: View {
    @ObservedObject private var downloads = DownloadController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(title: "Downloads", color: LumenTheme.sky)
                Spacer()
                Button("Clear finished") { downloads.clearFinished() }
                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.textDim))
                    .padding(.trailing, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if downloads.rows.isEmpty {
                        Text("Nothing downloading. Files save to Downloads.")
                            .font(LumenTheme.monoSmall)
                            .foregroundStyle(LumenTheme.textDim)
                            .padding(8)
                    }
                    ForEach(downloads.rows) { row in
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(color(row.state))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.filename)
                                    .font(LumenTheme.monoSmall)
                                    .foregroundStyle(LumenTheme.text)
                                    .lineLimit(1)
                                if row.state == .active {
                                    Rectangle()
                                        .fill(LumenTheme.sky)
                                        .frame(width: 120 * (row.fraction ?? 0.05), height: 3)
                                    Text(progressText(row))
                                        .font(LumenTheme.micro)
                                        .foregroundStyle(LumenTheme.textDim)
                                } else if let detail = row.detail {
                                    Text(detail).font(LumenTheme.micro).foregroundStyle(LumenTheme.textDim)
                                }
                            }
                            Spacer()
                            if row.state == .active {
                                Button("Cancel") { downloads.cancel(row.id) }
                                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.coral))
                            } else if row.state == .finished {
                                Button("Open") { downloads.open(row.id) }
                                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.lime))
                                Button("Finder") { downloads.reveal(row.id) }
                                    .buttonStyle(LumenButtonStyle(tint: LumenTheme.sky))
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
        .background(LumenTheme.bgRaised)
        .overlay(Rectangle().strokeBorder(LumenTheme.border, lineWidth: 1))
    }

    private func color(_ state: DownloadState) -> Color {
        switch state {
        case .active: return LumenTheme.sky
        case .finished: return LumenTheme.lime
        case .failed: return LumenTheme.coral
        case .cancelled: return LumenTheme.textDim
        }
    }

    private func progressText(_ row: DownloadRow) -> String {
        let written = MemoryFormat.megabytes(row.bytesWritten)
        if row.bytesExpected > 0 {
            return "\(written) / \(MemoryFormat.megabytes(row.bytesExpected))"
        }
        return written
    }
}

struct StatusBar: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var blocker = ContentBlocker.shared

    var body: some View {
        HStack(spacing: 10) {
            Text(session.focusedTab?.url?.host ?? (session.isPrivate ? "private" : "lumen"))
                .foregroundStyle(session.isPrivate ? LumenTheme.coral : LumenTheme.textDim)
            Spacer()
            let asleep = session.tabs.filter { $0.lifecycle == .suspended }.count
            if asleep > 0 {
                Text("\(asleep) asleep")
                    .foregroundStyle(LumenTheme.amber)
            }
            if session.measuredWebKit > 0 {
                Text("webkit \(MemoryFormat.megabytes(session.measuredWebKit))")
                    .foregroundStyle(LumenTheme.teal)
            }
            Text(blocker.phaseLabel)
                .foregroundStyle(LumenTheme.violet)
        }
        .font(LumenTheme.micro)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(LumenTheme.bgRaised)
        .overlay(alignment: .top) { Rectangle().fill(LumenTheme.border).frame(height: 1) }
    }
}
