import AppKit
import Foundation
import WebKit

final class SessionRegistry {
    static let shared = SessionRegistry()
    private struct WeakBox { weak var session: BrowserSession? }
    private var sessions: [UUID: WeakBox] = [:]

    func register(_ session: BrowserSession) { sessions[session.id] = WeakBox(session: session) }
    func unregister(_ id: UUID) { sessions.removeValue(forKey: id) }

    func all() -> [BrowserSession] {
        let live = sessions.values.compactMap(\.session)
        sessions = sessions.filter { $0.value.session != nil }
        return live
    }

    var keyWindowIsPrivate: Bool { all().contains { $0.isKey && $0.isPrivate } }
    var keySession: BrowserSession? { all().first { $0.isKey } ?? all().first }

    func suspendForMemory(critical: Bool) {
        all().forEach { $0.suspendForMemory(critical: critical) }
        ClipboardStore.shared.dropThumbnails()
    }

    func rebuildLiveWebViews() {
        all().forEach { $0.rebuildLiveWebViews() }
    }

    func setLocalWatch(_ enabled: Bool) {
        all().forEach { $0.setLocalWatch(enabled) }
    }
}

final class LaunchCoordinator {
    static let shared = LaunchCoordinator()
    private(set) var windows: [WindowSnapshot] = []
    private var openedExtras = false
    private var fresh = 1

    func load() {
        windows = SessionStore.shared.load()
        fresh = (windows.map(\.index).max() ?? 0) + 1
    }

    func snapshot(for index: Int) -> WindowSnapshot? {
        windows.first { $0.index == index }
    }

    func freshIndex() -> Int {
        fresh += 1
        return fresh
    }

    func openExtras(using open: (Int) -> Void) {
        guard !openedExtras else { return }
        openedExtras = true
        for window in windows where window.index != 0 {
            open(window.index)
        }
        SessionStore.shared.markLaunchComplete()
    }
}

final class BrowserSession: ObservableObject, Identifiable {
    let id = UUID()
    let launch: WindowLaunch
    let isPrivate: Bool
    let windowIndex: Int
    let dataStore: WKWebsiteDataStore
    let processPool: WKProcessPool
    let permissions: PermissionStore
    let popups = PopupCenter()

    @Published var tabs: [BrowserTab] = []
    @Published var groups: [TabGroup] = []
    @Published var primaryTabID: UUID?
    @Published var secondaryTabID: UUID?
    @Published var focusedPane: Pane = .primary
    @Published var splitFraction: CGFloat = 0.5
    @Published var sidebarVisible = false
    @Published var clipboardOnly = false
    @Published var sidebarWidth: Double = 248
    @Published var clipboardHeight: Double = 180
    @Published var grokVisible = false
    @Published var grokWidth: Double = 320
    @Published var downloadsVisible = false
    @Published var findVisible = false
    @Published var findQuery = ""
    @Published var findCount = 0
    @Published var findIndex = -1
    @Published var upperPane: UpperPane = .tabs
    @Published var addressFocusToken = 0
    @Published var findFocusToken = 0
    @Published var addressSeed: String?
    @Published var isKey = false
    @Published var measuredWebKit: Int64 = 0
    @Published var botNotice: String?
    @Published private(set) var chatStore: ChatStore?

    private var colorCursor = 0
    private var timer: Timer?
    private var localTimer: Timer?
    private var localTask: URLSessionDataTask?
    private var localWasDown = false
    private var localSignature: String?
    private var closed = false
    var isShutDown: Bool { closed }

    init(launch: WindowLaunch) {
        self.launch = launch
        self.isPrivate = launch.isPrivate
        self.windowIndex = launch.index
        if launch.isPrivate {
            dataStore = WKWebsiteDataStore.nonPersistent()
            processPool = WKProcessPool()
            permissions = PermissionStore(persistent: false)
        } else {
            dataStore = .default()
            processPool = WebKitPool.shared
            permissions = .shared
        }
        popups.session = self
        if !isPrivate, !ScreenshotLaunch.enabled, let snapshot = LaunchCoordinator.shared.snapshot(for: launch.index) {
            restore(snapshot)
        } else {
            let tab = makeTab(url: nil, title: "New Tab")
            tabs = [tab]
            primaryTabID = tab.id
        }
        SessionRegistry.shared.register(self)
        if !isPrivate { persist() }
        if SettingsStore.shared.localhostAutoReload { setLocalWatch(true) }
        let timer = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
            self?.suspendIdle()
            self?.refreshMemory()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        localTimer?.invalidate()
        localTask?.cancel()
        tabs.forEach { $0.releaseWebView() }
        popups.closeAll()
    }

    var focusedTab: BrowserTab? {
        let id = focusedPane == .primary ? primaryTabID : (secondaryTabID ?? primaryTabID)
        return tabs.first { $0.id == id }
    }

    var isSplit: Bool { secondaryTabID != nil }

    func tab(_ id: UUID?) -> BrowserTab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        timer = nil
        localTimer?.invalidate()
        localTimer = nil
        localTask?.cancel()
        localTask = nil
        chatStore?.cancel()
        tabs.forEach { $0.releaseWebView() }
        popups.closeAll()
        SessionRegistry.shared.unregister(id)
        if !isPrivate {
            SessionStore.shared.remove(index: windowIndex)
        }
    }

    func newTab(url: URL? = nil) {
        guard !closed else { return }
        let tab = makeTab(url: url, title: "New Tab")
        tabs.append(tab)
        show(tab, wake: false)
        if let url {
            tab.navigate(to: url)
        }
        persist()
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if tab.pinned { return }
        tab.releaseWebView()
        tabs.remove(at: index)
        if primaryTabID == id { primaryTabID = secondaryTabID ?? tabs.first?.id }
        if secondaryTabID == id { secondaryTabID = nil }
        if secondaryTabID == primaryTabID { secondaryTabID = nil }
        if focusedPane == .secondary && secondaryTabID == nil { focusedPane = .primary }
        if tabs.isEmpty {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        focusCurrent()
        persist()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let tab = tab(id) else { return }
        tab.pinned = pinned
        if pinned { tab.groupID = nil }
        persist()
    }

    func makeGroup(named name: String, tabID: UUID) {
        guard let tab = tab(tabID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let group = TabGroup(id: UUID(), name: String(trimmed.prefix(40)), colorIndex: tab.colorIndex, collapsed: false)
        groups.append(group)
        tab.groupID = group.id
        tab.pinned = false
        persist()
    }

    func setGroupCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].collapsed = collapsed
        if collapsed {
            if let focused = focusedTab, focused.groupID == id, let other = tabs.first(where: { !isCollapsed($0) }) {
                select(other.id)
            }
            for tab in tabs where tab.groupID == id && !tab.pinned {
                tab.suspend()
            }
        }
        persist()
    }

    func isCollapsed(_ tab: BrowserTab) -> Bool {
        guard let id = tab.groupID, let group = groups.first(where: { $0.id == id }) else { return false }
        return group.collapsed
    }

    func select(_ id: UUID) {
        guard tab(id) != nil else { return }
        if secondaryTabID == id {
            focusedPane = .secondary
        } else if primaryTabID == id {
            focusedPane = .primary
        } else if focusedPane == .secondary {
            secondaryTabID = id
        } else {
            primaryTabID = id
        }
        focusCurrent()
    }

    func focus(_ pane: Pane) {
        focusedPane = pane
        focusCurrent()
    }

    func toggleSplit() {
        if isSplit {
            closeSplit()
            return
        }
        guard let primary = primaryTabID, let index = tabs.firstIndex(where: { $0.id == primary }) else { return }
        let next = tabs[(index + 1) % tabs.count]
        if next.id == primary {
            let fresh = makeTab(url: nil, title: "New Tab")
            tabs.append(fresh)
            secondaryTabID = fresh.id
        } else {
            secondaryTabID = next.id
        }
        focusedPane = .secondary
        splitFraction = 0.5
        focusCurrent()
        persist()
    }

    func openInSplit(_ id: UUID) {
        guard tab(id) != nil else { return }
        if primaryTabID == nil { primaryTabID = id }
        if primaryTabID == id {
            toggleSplit()
            return
        }
        secondaryTabID = id
        focusedPane = .secondary
        focusCurrent()
        persist()
    }

    func swapSplit() {
        guard let secondary = secondaryTabID else { return }
        let primary = primaryTabID
        primaryTabID = secondary
        secondaryTabID = primary
        focusedPane = focusedPane == .primary ? .secondary : .primary
        persist()
    }

    func closeSplit() {
        guard let secondary = secondaryTabID else { return }
        if focusedPane == .secondary {
            primaryTabID = secondary
            focusedPane = .primary
        }
        secondaryTabID = nil
        if let other = tab(secondary), other.id != primaryTabID, !DownloadController.shared.isDownloading(other.id) {
            other.suspend()
        }
        persist()
    }

    func navigateFocused(to url: URL) {
        guard !closed else { return }
        if focusedTab == nil { newTab(url: url); return }
        focusedTab?.navigate(to: url)
        persist()
    }

    func reloadFocused() { focusedTab?.reload() }
    func back() { focusedTab?.goBack() }
    func forward() { focusedTab?.goForward() }
    func home() {
        if let url = URL(string: SettingsStore.shared.homePage) {
            navigateFocused(to: url)
        }
    }

    func focusAddress() { addressFocusToken += 1 }

    func showInspector() {
        guard let webView = focusedTab?.webView else { return }
        WebInspector.show(webView)
    }

    func copyPageMarkdown() {
        focusedTab?.copyReadableMarkdown()
    }

    @Published var viewportOpen = false
    func showFind() {
        findVisible = true
        findFocusToken += 1
    }

    func updateFind(reset: Bool) {
        guard findVisible, let tab = focusedTab else { return }
        if tab.webView == nil { tab.wake() }
        tab.runFind(query: findQuery, reset: reset) { [weak self] count, index in
            self?.findCount = count
            self?.findIndex = index
        }
    }

    func findStep(forward: Bool) {
        guard let tab = focusedTab else { return }
        tab.runFind(query: forward ? "next" : "prev", reset: false) { [weak self] count, index in
            self?.findCount = count
            self?.findIndex = index
        }
    }

    func closeFind() {
        findVisible = false
        focusedTab?.clearFind()
        findCount = 0
        findIndex = -1
    }

    func ensureChat() {
        if chatStore == nil {
            chatStore = ChatStore(isPrivate: isPrivate)
        }
    }

    func toggleGrok() {
        if grokVisible {
            grokVisible = false
            return
        }
        ensureChat()
        grokVisible = true
    }

    func adoptExternalTab(configuration: WKWebViewConfiguration) -> WKWebView {
        let tab = makeTab(url: nil, title: "New Tab")
        let view = WKWebView(frame: .zero, configuration: configuration)
        tab.adopt(view, capturePasswords: !isPrivate, pageGhost: SettingsStore.shared.pageFieldGhost && !isPrivate)
        tabs.append(tab)
        show(tab, wake: false)
        persist()
        return view
    }

    func persist() {
        guard !isPrivate, !closed else { return }
        SessionStore.shared.update(snapshot())
    }

    func suspendForMemory(critical: Bool) {
        guard MemoryPressureCenter.shared.isUnderPressure || critical else { return }
        discardBackgroundTabs(pressure: true, critical: critical || MemoryPressureCenter.shared.critical)
        if critical {
            chatStore?.trimHard()
        } else {
            chatStore?.trimSoft()
        }
    }

    func setLocalWatch(_ enabled: Bool) {
        localTimer?.invalidate()
        localTimer = nil
        localTask?.cancel()
        localTask = nil
        guard enabled else {
            localWasDown = false
            localSignature = nil
            return
        }
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.pollLocalhost()
        }
        RunLoop.main.add(timer, forMode: .common)
        localTimer = timer
    }

    func rebuildLiveWebViews() {
        let shown: Set<UUID> = Set([primaryTabID, secondaryTabID].compactMap { $0 })
        let live = tabs.filter { $0.webView != nil }
        for tab in live where !DownloadController.shared.isDownloading(tab.id) {
            tab.suspend()
            if shown.contains(tab.id), tab.url != nil {
                tab.wake()
            }
        }
    }

    func omniboxEntries() -> [Omnibox.Entry] {
        var entries: [Omnibox.Entry] = []
        if !isPrivate {
            entries.append(contentsOf: HistoryStore.shared.omniboxEntries)
        }
        entries.append(contentsOf: BookmarkStore.shared.omniboxEntries())
        for tab in tabs {
            guard let url = tab.url, let host = url.host else { continue }
            entries.append(Omnibox.Entry(
                urlString: url.absoluteString,
                host: host,
                title: String(tab.title.prefix(80)),
                frecency: 3,
                kind: .tab,
                tabID: tab.id
            ))
        }
        return entries
    }

    func openGrokBot(sendPage: Bool) {
        let raw = SettingsStore.shared.grokBotURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), !raw.isEmpty else {
            botNotice = "Set a Grok Bot URL in Settings."
            return
        }
        guard sendPage else {
            if !NSWorkspace.shared.open(url) {
                botNotice = "Could not open \(raw). Install Grok Bot, or change the URL in Settings."
            }
            return
        }
        let fallbackURL = focusedTab?.url?.absoluteString ?? ""
        let deliver: (String, String, String) -> Void = { [weak self] title, selection, text in
            var lines = [title, fallbackURL]
            if !selection.isEmpty {
                lines.append(selection)
            } else if !text.isEmpty {
                lines.append(String(text.prefix(4_000)))
            }
            let payload = lines.filter { !$0.isEmpty }.joined(separator: "\n")
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(payload, forType: .string)
            if !NSWorkspace.shared.open(url) {
                self?.botNotice = "Copied the page. Nothing accepted \(raw)."
            }
        }
        if let tab = focusedTab {
            tab.pageSnapshot { title, selection, text in
                deliver(title, selection, text)
            }
        } else {
            deliver("", "", "")
        }
    }

    func paste(text: String, intoAddress: Bool) {
        if intoAddress {
            addressSeed = text
            addressFocusToken += 1
            return
        }
        if focusedTab?.webView == nil {
            addressSeed = text
            addressFocusToken += 1
            return
        }
        let targetID = focusedTab?.id
        focusedTab?.insert(text) { [weak self] inserted in
            guard let self, !inserted, self.focusedTab?.id == targetID else { return }
            self.addressSeed = text
            self.addressFocusToken += 1
        }
    }

    private func restore(_ snapshot: WindowSnapshot) {
        sidebarWidth = min(420, max(200, snapshot.sidebarWidth))
        splitFraction = CGFloat(min(0.75, max(0.25, snapshot.splitFraction)))
        focusedPane = snapshot.focusedPane
        groups = snapshot.groups
        tabs = snapshot.tabs.map { item in
            let tab = makeTab(
                url: item.url.flatMap(URL.init(string:)),
                title: item.title.isEmpty ? "New Tab" : item.title,
                id: item.id,
                colorIndex: item.colorIndex
            )
            tab.pinned = item.pinned
            tab.groupID = item.groupID
            return tab
        }
        if tabs.isEmpty {
            let tab = makeTab(url: nil, title: "New Tab")
            tabs = [tab]
        }
        primaryTabID = snapshot.primaryTabID ?? tabs.first?.id
        if let secondary = snapshot.secondaryTabID, secondary != primaryTabID, tab(secondary) != nil {
            secondaryTabID = secondary
        }
        colorCursor = (tabs.map(\.colorIndex).max() ?? 0) + 1
        focusCurrent()
    }

    private func focusCurrent() {
        let tab = focusedTab
        tab?.lastFocused = Date()
        tab?.focusCount += 1
        if let tab, tab.url != nil, tab.webView == nil, !isCollapsed(tab) {
            tab.wake()
        }
    }

    private func show(_ tab: BrowserTab, wake: Bool) {
        if focusedPane == .secondary, secondaryTabID != nil {
            secondaryTabID = tab.id
        } else {
            primaryTabID = tab.id
            focusedPane = .primary
        }
        tab.lastFocused = Date()
        if wake, tab.url != nil { tab.wake() }
    }

    private func makeTab(url: URL?, title: String, id: UUID = UUID(), colorIndex: Int? = nil) -> BrowserTab {
        let color = colorIndex ?? colorCursor
        if colorIndex == nil { colorCursor += 1 }
        let tab = BrowserTab(id: id, url: url, title: title, colorIndex: color, session: self)
        return tab
    }

    func suspendIdle() {
        let mode = SettingsStore.shared.tabSleepMode
        let pressure = MemoryPressureCenter.shared.isUnderPressure
        if mode == .off && !pressure { return }
        discardBackgroundTabs(pressure: pressure, critical: MemoryPressureCenter.shared.critical)
    }

    private func discardBackgroundTabs(pressure: Bool, critical: Bool) {
        let now = Date()
        let neighborIDs = neighborTabIDs()
        let visible = visibleTabIDs()
        let inputs = tabs.map { tab in
            TabSleepInput(
                id: tab.id,
                pinned: tab.pinned,
                visible: visible.contains(tab.id),
                neighbor: neighborIDs.contains(tab.id),
                lastFocused: tab.lastFocused,
                focusCount: max(1, tab.focusCount),
                loading: tab.isLoading,
                downloading: DownloadController.shared.isDownloading(tab.id),
                capturing: false,
                hasWebView: tab.webView != nil
            )
        }
        let chosen = TabSleepPolicy.candidates(
            tabs: inputs,
            mode: SettingsStore.shared.tabSleepMode,
            aggressiveMinutes: SettingsStore.shared.suspendMinutes,
            pressure: pressure,
            critical: critical,
            now: now
        )
        for id in chosen {
            guard let tab = tab(id), let view = tab.webView, !tab.capturingMedia() else { continue }
            view.evaluateJavaScript(PageScripts.sleepSnapshot) { [weak self, weak tab, weak view] result, error in
                guard let self, let tab, let view, error == nil, tab.webView === view else { return }
                guard !tab.pinned, !self.visibleTabIDs().contains(tab.id), !self.neighborTabIDs().contains(tab.id) else { return }
                guard !tab.isLoading, !DownloadController.shared.isDownloading(tab.id), !tab.capturingMedia() else { return }
                let info = result as? [String: Any]
                let media = (info?["media"] as? Bool) ?? (info?["media"] as? NSNumber)?.boolValue ?? true
                let dirty = (info?["dirty"] as? Bool) ?? (info?["dirty"] as? NSNumber)?.boolValue ?? true
                if media || dirty { return }
                let x = (info?["x"] as? Double) ?? (info?["x"] as? NSNumber)?.doubleValue ?? 0
                let y = (info?["y"] as? Double) ?? (info?["y"] as? NSNumber)?.doubleValue ?? 0
                if let url = view.url?.absoluteString {
                    tab.scrollRestore = (x, y, url)
                }
                if critical { tab.favicon = nil }
                tab.suspend()
            }
        }
    }

    private func visibleTabIDs() -> Set<UUID> {
        Set([primaryTabID, secondaryTabID].compactMap { $0 })
    }

    private func neighborTabIDs() -> Set<UUID> {
        var ids = Set<UUID>()
        let visible = visibleTabIDs()
        for id in visible {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            if index > 0 { ids.insert(tabs[index - 1].id) }
            if index + 1 < tabs.count { ids.insert(tabs[index + 1].id) }
        }
        if let recent = tabs.filter({ !visible.contains($0.id) }).max(by: { $0.lastFocused < $1.lastFocused }) {
            ids.insert(recent.id)
        }
        ids.subtract(visible)
        return ids
    }

    private func pollLocalhost() {
        guard SettingsStore.shared.localhostAutoReload,
              let tab = focusedTab,
              let url = tab.url,
              let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1",
              tab.webView != nil else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 1.5
        localTask?.cancel()
        localTask = URLSession.shared.dataTask(with: request) { [weak self, weak tab] _, response, error in
            DispatchQueue.main.async {
                guard let self, let tab else { return }
                self.noteLocalhost(response: response as? HTTPURLResponse, error: error, tab: tab)
            }
        }
        localTask?.resume()
    }

    private func noteLocalhost(response: HTTPURLResponse?, error: Error?, tab: BrowserTab) {
        if error != nil || (response?.statusCode ?? 500) >= 500 {
            localWasDown = true
            return
        }
        let signature = response?.value(forHTTPHeaderField: "ETag")
            ?? response?.value(forHTTPHeaderField: "Last-Modified")
            ?? response.map { "\($0.statusCode)" }
        let cameBack = localWasDown
        let changed = localSignature != nil && signature != localSignature
        localWasDown = false
        localSignature = signature
        if (cameBack || changed), !closed, tab.webView != nil {
            tab.reload()
        }
    }

    private func refreshMemory() {
        let live = tabs.filter { $0.webView != nil }
        let footprint = ProcessFootprint.sample()
        measuredWebKit = footprint.map { $0.webContentBytes + $0.helperBytes } ?? 0
        if live.count == 1, let bytes = footprint?.webContentBytes, bytes > 0 {
            live[0].memory = TabMemory(bytes: bytes, kind: .measured)
            return
        }
        for tab in live {
            tab.refreshHeuristic()
        }
    }

    private func snapshot() -> WindowSnapshot {
        WindowSnapshot(
            index: windowIndex,
            tabs: tabs.map {
                TabSnapshot(id: $0.id, url: $0.url?.absoluteString, title: $0.title, colorIndex: $0.colorIndex, pinned: $0.pinned, groupID: $0.groupID)
            },
            groups: groups,
            primaryTabID: primaryTabID,
            secondaryTabID: secondaryTabID,
            focusedPane: focusedPane,
            splitFraction: Double(splitFraction),
            sidebarWidth: sidebarWidth
        )
    }
}
