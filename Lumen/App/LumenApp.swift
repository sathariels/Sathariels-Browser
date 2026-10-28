import AppKit
import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        LaunchCoordinator.shared.load()
    }

    var body: some Scene {
        WindowGroup(id: "browser", for: WindowLaunch.self) { $launch in
            BrowserRoot(launch: launch ?? WindowLaunch(index: 0, isPrivate: false))
        } defaultValue: {
            WindowLaunch(index: 0, isPrivate: false)
        }
        .defaultSize(width: 1180, height: 780)
        .commands { LumenCommands() }

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
                guard launch.index == 0, !launch.isPrivate else { return }
                LaunchCoordinator.shared.openExtras { index in
                    openWindow(value: WindowLaunch(index: index, isPrivate: false))
                }
            }
            .focusedValue(\.browserActions, BrowserActions(
                newTab: { session.newTab() },
                closeTab: { if let id = session.focusedTab?.id { session.closeTab(id) } },
                focusAddress: { session.focusAddress() },
                reload: { session.reloadFocused() },
                back: { session.back() },
                forward: { session.forward() },
                find: { session.showFind() },
                findNext: { session.findStep(forward: true) },
                findPrev: { session.findStep(forward: false) },
                toggleGrok: { session.toggleGrok() },
                toggleSplit: { session.toggleSplit() },
                swapSplit: { session.swapSplit() },
                closeSplit: { session.closeSplit() },
                toggleDownloads: { session.downloadsVisible.toggle() },
                toggleSidebar: { session.sidebarVisible.toggle() },
                selectTab: { index in
                    guard session.tabs.indices.contains(index) else { return }
                    session.select(session.tabs[index].id)
                }
            ))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ContentBlocker.shared.prepare()
        MemoryPressureCenter.shared.onPressure = { critical in
            SessionRegistry.shared.suspendForMemory(critical: critical)
        }
        MemoryPressureCenter.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.shared.saveNow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }
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
    var toggleGrok: () -> Void
    var toggleSplit: () -> Void
    var swapSplit: () -> Void
    var closeSplit: () -> Void
    var toggleDownloads: () -> Void
    var toggleSidebar: () -> Void
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

struct LumenCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.browserActions) private var actions

    var body: some Commands {
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
        }
        CommandMenu("Tabs") {
            ForEach(1..<10, id: \.self) { number in
                Button("Select Tab \(number)") { actions?.selectTab(number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}
