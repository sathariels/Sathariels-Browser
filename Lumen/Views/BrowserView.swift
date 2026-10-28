import AppKit
import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @State private var sidebarOrigin: Double?
    @State private var grokOrigin: Double?
    @State private var splitOrigin: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            if session.isPrivate {
                Rectangle().fill(LumenTheme.coral).frame(height: 2)
            }
            TabStrip(session: session)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: bookmarks.bookmarks.isEmpty ? 45 : 76)
                    if session.viewportOpen, let tab = session.focusedTab {
                        ViewportBar(tab: tab)
                    }
                    if session.findVisible { FindBar(session: session) }
                    BannerHost(session: session)
                    GeometryReader { workspace in
                    HStack(spacing: 0) {
                        BrowserRail(session: session)
                        if session.grokVisible, let chat = session.chatStore {
                            GrokPanel(session: session, chat: chat)
                                .frame(width: min(session.grokWidth, max(280, workspace.size.width * 0.30)))
                            dragHandle(width: false)
                        } else if session.sidebarVisible {
                            SidebarView(session: session)
                                .frame(width: min(session.sidebarWidth, max(200, workspace.size.width * 0.24)))
                            dragHandle(width: true)
                        }
                        ZStack(alignment: .topTrailing) {
                            split
                            if session.downloadsVisible {
                                DownloadsPanel()
                                    .frame(width: min(420, max(220, workspace.size.width * 0.48)), height: 240)
                                    .padding(8)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    }
                    }
                    StatusBar(session: session)
                }
                AddressBarHost(session: session)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .zIndex(2)
            }
        }
        .background(LumenTheme.bg)
        .ignoresSafeArea(.container, edges: .top)
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
            .fill(LumenTheme.border.opacity(0.5))
            .frame(width: 4)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if width {
                            if sidebarOrigin == nil { sidebarOrigin = session.sidebarWidth }
                            session.sidebarWidth = min(420, max(200, (sidebarOrigin ?? 248) + value.translation.width))
                        } else {
                            if grokOrigin == nil { grokOrigin = session.grokWidth }
                            session.grokWidth = min(520, max(260, (grokOrigin ?? 320) + value.translation.width))
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
                    .frame(width: session.isSplit ? max(0, geo.size.width - 4) * session.splitFraction : nil)
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
                .fill(session.isSplit && session.focusedPane == pane ? LumenTheme.tabColor(session.tab(id)?.colorIndex ?? 0) : Color.clear)
                .frame(height: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { session.focus(pane) }
    }
}

struct TabStrip: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject private var extensions = ExtensionMenuModel.shared
    @State private var leading: CGFloat = 76
    @State private var stripHover = false
    @State private var lockedWidth: CGFloat?
    @State private var laidOutWidth: CGFloat = 190

    private let tabMax: CGFloat = 240
    private let tabMin: CGFloat = 36
    private let gap: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let pins = session.tabs.filter(\.pinned)
                let loose = session.tabs.filter { !$0.pinned && !session.isCollapsed($0) }
                let reserved = CGFloat(pins.count) * 40 + CGFloat(max(pins.count - 1, 0)) * gap + groupChrome + 36
                let available = max(0, geo.size.width - reserved - 8)
                let natural = loose.isEmpty ? tabMax : min(tabMax, max(tabMin, (available - gap * CGFloat(max(loose.count - 1, 0))) / CGFloat(loose.count)))
                let width = lockedWidth.map { min(natural, $0) } ?? natural
                let needsScroll = !loose.isEmpty && CGFloat(loose.count) * tabMin + gap * CGFloat(loose.count - 1) > available
                strip(pins: pins, loose: loose, tabWidth: needsScroll ? tabMin : width, scroll: needsScroll)
                    .onChange(of: loose.count) { old, new in
                        if new < old && stripHover {
                            lockedWidth = laidOutWidth
                        }
                    }
                    .onChange(of: natural) { _, value in
                        if lockedWidth == nil { laidOutWidth = value }
                    }
            }
            if session.isPrivate {
                Text("PRIVATE")
                    .font(LumenTheme.micro)
                    .foregroundStyle(LumenTheme.coral)
                    .padding(.horizontal, 8)
            }
            extensionButton
        }
        .padding(.leading, leading)
        .frame(height: 39, alignment: .bottom)
        .background(WindowDrag())
        .background(TrafficInset(leading: $leading))
        .onHover { inside in
            stripHover = inside
            if !inside { lockedWidth = nil }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(LumenTheme.border).frame(height: 1)
        }
    }

    private var groupChrome: CGFloat {
        session.groups.reduce(0) { partial, group in
            let visible = session.tabs.contains { $0.groupID == group.id && !$0.pinned }
            return partial + (visible ? 92 : 0)
        }
    }

    private func strip(pins: [BrowserTab], loose: [BrowserTab], tabWidth: CGFloat, scroll: Bool) -> some View {
        let row = HStack(spacing: gap) {
            ForEach(pins) { tab in
                TabChip(session: session, tab: tab, width: 40, compact: true)
            }
            ForEach(session.groups) { group in
                if session.tabs.contains(where: { $0.groupID == group.id && !$0.pinned }) {
                    GroupChip(session: session, group: group)
                    if !group.collapsed {
                        ForEach(loose.filter { $0.groupID == group.id }) { tab in
                            TabChip(session: session, tab: tab, width: tabWidth, compact: tabWidth < 72)
                        }
                    }
                }
            }
            ForEach(loose.filter { $0.groupID == nil }) { tab in
                TabChip(session: session, tab: tab, width: tabWidth, compact: tabWidth < 72)
            }
            Button {
                session.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LumenTheme.activeText)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New tab")
        }
        .padding(.leading, 4)
        return Group {
            if scroll {
                ScrollView(.horizontal, showsIndicators: false) { row }
            } else {
                row
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var extensionButton: some View {
        Menu {
            if extensions.available {
                if extensions.names.isEmpty {
                    Text("No folders loaded")
                }
                ForEach(extensions.names, id: \.self) { name in
                    Text(name)
                }
                Button("Load Folder…") { ExtensionSupport.pickFolder() }
            } else {
                Text("Needs macOS 15.4")
            }
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LumenTheme.tabText)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Web extensions")
    }
}

struct GroupChip: View {
    @ObservedObject var session: BrowserSession
    let group: TabGroup

    var body: some View {
        Button {
            session.setGroupCollapsed(group.id, !group.collapsed)
        } label: {
            HStack(spacing: 4) {
                Rectangle().fill(LumenTheme.tabColor(group.colorIndex)).frame(width: 8, height: 8)
                Text(group.name)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(LumenTheme.tabText)
                    .lineLimit(1)
                Text(group.collapsed ? "+" : "–")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(LumenTheme.textDim)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
        }
        .buttonStyle(.plain)
        .background(LumenTheme.tabIdle)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .help(group.collapsed ? "Expand group" : "Collapse group")
    }
}

struct TabChip: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab
    var width: CGFloat = 190
    var compact: Bool = false
    @State private var hover = false

    var body: some View {
        let active = session.focusedTab?.id == tab.id
        let showClose = !tab.pinned && (active || hover)
        HStack(spacing: compact ? 4 : 8) {
            favicon
            if !compact && !tab.pinned {
                Text(tab.title.isEmpty ? "New tab" : tab.title)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(active ? LumenTheme.activeText : LumenTheme.tabText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, tab.pinned ? 6 : 8)
        .contentShape(Rectangle())
        .onTapGesture { session.select(tab.id) }
        .overlay(alignment: .trailing) {
            if showClose {
                Button {
                    session.closeTab(tab.id)
                } label: {
                    Text("×")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color(red: 135 / 255, green: 145 / 255, blue: 139 / 255))
                        .frame(width: 16, height: 16)
                        .background(active ? LumenTheme.toolbar : LumenTheme.bg)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .help("Close tab")
            }
        }
        .frame(width: width, height: 32)
        .background(active ? LumenTheme.toolbar : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .top) {
            Capsule().fill(active ? LumenTheme.accent : Color.clear).frame(width: min(32, width - 8), height: 2)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { tabMenu }
    }

    @ViewBuilder
    private var favicon: some View {
        if let image = tab.favicon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "leaf.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LumenTheme.markLeaf)
                .frame(width: 18, height: 18)
                .background(LumenTheme.mark)
        }
    }

    @ViewBuilder
    private var tabMenu: some View {
        Button("Open in Split") { session.openInSplit(tab.id) }
        Button("Reload") { session.select(tab.id); session.reloadFocused() }
        Button("Copy URL") {
            if let url = tab.url?.absoluteString {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
        Button(tab.pinned ? "Unpin" : "Pin") { session.setPinned(tab.id, !tab.pinned) }
        Button("New Group…") { TabGroupPrompt.create(session: session, tabID: tab.id) }
        Menu("Color") {
            ForEach(0..<LumenTheme.tabPalette.count, id: \.self) { index in
                Button("Tag \(index + 1)") { tab.colorIndex = index }
            }
        }
        if !tab.pinned {
            Button("Close") { session.closeTab(tab.id) }
        }
    }
}

enum TabGroupPrompt {
    static func create(session: BrowserSession, tabID: UUID) {
        let alert = NSAlert()
        alert.messageText = "New tab group"
        alert.informativeText = "Collapsed groups drop their web views until you open the group."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "Group"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.makeGroup(named: field.stringValue, tabID: tabID)
    }
}

struct WindowDrag: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.wantsLayer = true
        view.layer?.backgroundColor = LumenTheme.windowBackground.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = LumenTheme.windowBackground.cgColor
    }

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct TrafficInset: NSViewRepresentable {
    @Binding var leading: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = PassHitView()
        view.onMove = { [weak view] in
            guard let window = view?.window else { return }
            let full = window.styleMask.contains(.fullScreen)
            let next: CGFloat = full ? 8 : 76
            if leading != next { leading = next }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PassHitView)?.onMove = { [weak nsView] in
            guard let window = nsView?.window else { return }
            let full = window.styleMask.contains(.fullScreen)
            let next: CGFloat = full ? 8 : 76
            if leading != next { leading = next }
        }
        let full = nsView.window?.styleMask.contains(.fullScreen) == true
        let next: CGFloat = full ? 8 : 76
        if leading != next { leading = next }
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
            if let warning = tab.pageWarning {
                PageWarningView(warning: warning) { tab.allowCurrentWarning() }
            } else if let document = tab.jsonDocument {
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

struct PageWarningView: View {
    let warning: PageWarning
    let proceed: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(LumenTheme.title)
                .foregroundStyle(LumenTheme.text)
            Text(detail)
                .font(LumenTheme.monoSmall)
                .foregroundStyle(LumenTheme.textDim)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 520)
            Button("Continue anyway", action: proceed)
                .buttonStyle(LumenButtonStyle(tint: tint))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch warning {
        case .httpsFailed: return "HTTPS is unavailable"
        case .unsafe: return "This site looks unsafe"
        }
    }

    private var detail: String {
        switch warning {
        case .httpsFailed(let url):
            return "\(url.absoluteString) did not load over HTTPS."
        case .unsafe(let url):
            return "\(url.host ?? url.absoluteString) matches a local phishing or malware list. The address was not sent to a lookup service."
        }
    }

    private var tint: Color {
        switch warning {
        case .httpsFailed: return LumenTheme.amber
        case .unsafe: return LumenTheme.coral
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
        guard let window = nsView.window else { return }
        window.title = session.isPrivate ? "Private — Sathariels Browser" : (session.focusedTab?.title ?? "Sathariels Browser")
        window.backgroundColor = LumenTheme.windowBackground
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        ScreenshotLaunch.place(window)
    }

    final class ProbeView: NSView {
        weak var session: BrowserSession?
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
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
            Text(session.focusedTab?.url?.host ?? (session.isPrivate ? "private" : "sathariels"))
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
        .background(LumenTheme.strip)
        .overlay(alignment: .top) { Rectangle().fill(LumenTheme.tabLine).frame(height: 1) }
    }
}
