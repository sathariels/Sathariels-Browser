import Foundation

/// Writes the open regular windows often enough that a crash keeps the last tabs.
final class SessionStore {
    static let shared = SessionStore()

    private var windows: [Int: WindowSnapshot] = [:]
    private var launchComplete = false
    private var work: DispatchWorkItem?
    private let file = "session.json"

    private init() {}

    func seed(_ snapshots: [WindowSnapshot]) {
        windows = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.index, $0) })
    }

    func update(_ snapshot: WindowSnapshot) {
        windows[snapshot.index] = snapshot
        guard launchComplete, SettingsStore.shared.restoreSession else { return }
        schedule()
    }

    func remove(index: Int) {
        windows.removeValue(forKey: index)
        guard launchComplete else { return }
        schedule()
    }

    func markLaunchComplete() {
        launchComplete = true
        guard SettingsStore.shared.restoreSession else { return }
        saveNow()
    }

    func forget() {
        windows = [:]
        work?.cancel()
        JSONStore.remove(file)
    }

    func load() -> [WindowSnapshot] {
        guard SettingsStore.shared.restoreSession else { return [] }
        let file = JSONStore.load(self.file, as: SessionFile.self)
        let windows = file?.windows ?? []
        seed(windows)
        return windows.sorted { $0.index < $1.index }
    }

    func saveNow() {
        work?.cancel()
        guard SettingsStore.shared.restoreSession else { return }
        let payload = SessionFile(version: 1, windows: windows.values.sorted { $0.index < $1.index })
        JSONStore.save(payload, as: file)
    }

    private func schedule() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }
}
