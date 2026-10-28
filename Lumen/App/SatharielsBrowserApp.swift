import AppKit
import Sparkle
import SwiftUI

@main
struct SatharielsBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        CrashCenter.install()
        RuleCompile.parse()
        ScreenshotLaunch.parse()
        LaunchCoordinator.shared.load()
        CrashCenter.prepareForLaunch()
    }

    var body: some Scene {
        WindowGroup(id: "browser", for: WindowLaunch.self) { $launch in
            BrowserRoot(launch: launch)
        } defaultValue: {
            WindowLaunch(index: 0, isPrivate: false)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { SatharielsBrowserCommands() }

        Settings {
            SettingsView()
        }
    }
}

struct BrowserRoot: View {
    let launch: WindowLaunch
    @StateObject private var session: BrowserSession
    @Environment(\.openWindow) private var openWindow

    init(launch: WindowLaunch) {
        self.launch = launch
        _session = StateObject(wrappedValue: BrowserSession(launch: launch))
    }

    var body: some View {
        BrowserView(session: session)
            .onAppear {
                if launch.index == 0, !launch.isPrivate {
                    ScreenshotLaunch.apply(to: session)
                }
                guard launch.index == 0, !launch.isPrivate, !ScreenshotLaunch.enabled else { return }
                LaunchCoordinator.shared.openExtras { index in
                    openWindow(value: WindowLaunch(index: index, isPrivate: false))
                }
            }
            .focusedSceneValue(\.browserActions, BrowserActions(
                newTab: { session.newTab() },
                closeTab: { if let id = session.focusedTab?.id { session.closeTab(id) } },
                focusAddress: { session.focusAddress() },
                reload: { session.reloadFocused() },
                back: { session.back() },
                forward: { session.forward() },
                find: { session.showFind() },
                findNext: { session.findStep(forward: true) },
                findPrev: { session.findStep(forward: false) },
                history: { session.showHistory() },
                command: { session.showCommand() },
                bookmark: { session.bookmarkFocused() },
                zoomIn: { session.changeZoom(1) },
                zoomOut: { session.changeZoom(-1) },
                zoomReset: { session.changeZoom(0) },
                memory: { session.showMemory() },
                pictureInPicture: { session.pictureInPicture() },
                toggleGrok: { session.toggleGrok() },
                toggleSplit: { session.toggleSplit() },
                swapSplit: { session.swapSplit() },
                closeSplit: { session.closeSplit() },
                toggleDownloads: { session.downloadsVisible.toggle() },
                toggleSidebar: { session.sidebarVisible.toggle() },
                inspect: { session.showInspector() },
                copyMarkdown: { session.copyPageMarkdown() },
                toggleReader: { session.focusedTab?.toggleReader() },
                selectTab: { index in
                    guard session.tabs.indices.contains(index) else { return }
                    session.select(session.tabs[index].id)
                }
            ))
    }
}

enum RuleCompile {
    static var directory: URL?

    static func parse() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--precompile-rules"), args.indices.contains(index + 1) else { return }
        directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }
}

enum ScreenshotLaunch {
    static var enabled = false
    static var url: URL?
    static var focusAddress = false
    static var readyPath: String?
    static var memoryTabs = 0
    private static var applied = false
    private static var placed = false

    static func parse() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if let raw = value(after: "--screenshot-url") {
            url = URL(string: raw)
        }
        focusAddress = args.contains("--focus-address")
        readyPath = value(after: "--screenshot-ready")
        if let raw = value(after: "--memory-tabs"), let count = Int(raw) {
            memoryTabs = min(12, max(0, count))
        }
        enabled = url != nil || focusAddress || readyPath != nil || memoryTabs > 0
    }

    static func apply(to session: BrowserSession) {
        guard enabled, !applied else { return }
        applied = true
        if let url {
            session.navigateFocused(to: url)
        }
        if memoryTabs > 1 {
            for _ in 1..<memoryTabs {
                session.newTab(url: URL(string: "about:blank"))
            }
        }
        let delay: TimeInterval = url == nil ? 0.8 : 6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if focusAddress {
                session.focusAddress()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let payload = Data("ready\n".utf8)
                if let readyPath {
                    try? payload.write(to: URL(fileURLWithPath: readyPath))
                }
                if let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? payload.write(to: folder.appendingPathComponent("screenshot-ready"))
                }
                NSLog("SCREENSHOT_READY")
            }
        }
    }

    static func place(_ window: NSWindow) {
        guard enabled, !placed else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        placed = true
        let visible = screen.visibleFrame
        let size = NSSize(width: min(1200, visible.width - 80), height: min(800, visible.height - 80))
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftUI window that is not key never installs a field editor, so the
        // address bar ignores typing until the app is a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if RuleCompile.directory == nil, !ScreenshotLaunch.enabled, let report = CrashCenter.takeReport() {
            CrashCenter.present(report)
        }
        if let directory = RuleCompile.directory {
            Task { @MainActor in
                await ContentBlocker.shared.precompileBundled(to: directory)
                exit(0)
            }
            return
        }
        startUpdaterIfSigned()
        if !ScreenshotLaunch.enabled {
            AppUpdateCenter.shared.scheduleAutomaticCheck()
        }
        ExtensionSupport.restoreSaved()
        ThreatList.shared.prepare()
        MemoryPressureCenter.shared.onPressure = { critical in
            SessionRegistry.shared.suspendForMemory(critical: critical)
        }
        MemoryPressureCenter.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionRegistry.shared.keySession?.focusedTab?.captureInteractionState()
        SessionStore.shared.saveNow()
        CrashCenter.markClean()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// Sparkle stays unloaded until a release embeds SUPublicEDKey. Dev builds skip the
    /// updater process so an empty key does not start background feed checks.
    private func startUpdaterIfSigned() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty, !key.hasPrefix("$(") else { return }
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
}

struct BrowserActions {
    var newTab: () -> Void
    var closeTab: () -> Void
    var focusAddress: () -> Void
    var reload: () -> Void
    var back: () -> Void
    var forward: () -> Void
    var find: () -> Void
    var findNext: () -> Void
    var findPrev: () -> Void
    var history: () -> Void
    var command: () -> Void
    var bookmark: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var zoomReset: () -> Void
    var memory: () -> Void
    var pictureInPicture: () -> Void
    var toggleGrok: () -> Void
    var toggleSplit: () -> Void
    var swapSplit: () -> Void
    var closeSplit: () -> Void
    var toggleDownloads: () -> Void
    var toggleSidebar: () -> Void
    var inspect: () -> Void
    var copyMarkdown: () -> Void
    var toggleReader: () -> Void
    var selectTab: (Int) -> Void
}

struct BrowserActionsKey: FocusedValueKey {
    typealias Value = BrowserActions
}

extension FocusedValues {
    var browserActions: BrowserActions? {
        get { self[BrowserActionsKey.self] }
        set { self[BrowserActionsKey.self] = newValue }
    }
}

struct SatharielsBrowserCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.browserActions) private var actions

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                AppUpdateCenter.shared.check(manual: true)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { actions?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Window") {
                openWindow(value: WindowLaunch(index: LaunchCoordinator.shared.freshIndex(), isPrivate: false))
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("New Private Window") {
                openWindow(value: WindowLaunch(index: LaunchCoordinator.shared.freshIndex(), isPrivate: true))
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close Tab") { actions?.closeTab() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Load Extension Folder…") { ExtensionSupport.pickFolder() }
        }
        CommandGroup(after: .toolbar) {
            Button("Open Location") { actions?.focusAddress() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Reload") { actions?.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Back") { actions?.back() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { actions?.forward() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Find…") { actions?.find() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { actions?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { actions?.findPrev() }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Divider()
            Button("History") { actions?.history() }
                .keyboardShortcut("y", modifiers: .command)
            Button("Search Tabs and Library") { actions?.command() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Bookmark This Page") { actions?.bookmark() }
                .keyboardShortcut("d", modifiers: .command)
            Divider()
            Button("Zoom In") { actions?.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { actions?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { actions?.zoomReset() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Tab Memory") { actions?.memory() }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Picture in Picture") { actions?.pictureInPicture() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Toggle Grok") { actions?.toggleGrok() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Toggle Downloads") { actions?.toggleDownloads() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Button("Toggle Split") { actions?.toggleSplit() }
                .keyboardShortcut("\\", modifiers: .command)
            Button("Swap Split") { actions?.swapSplit() }
                .keyboardShortcut("\\", modifiers: [.command, .option])
            Button("Close Split") { actions?.closeSplit() }
            Divider()
            Button("Inspect Element") { actions?.inspect() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Copy Page as Markdown") { actions?.copyMarkdown() }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Reading Mode") { actions?.toggleReader() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Tabs") {
            ForEach(1..<10, id: \.self) { number in
                Button("Select Tab \(number)") { actions?.selectTab(number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}
