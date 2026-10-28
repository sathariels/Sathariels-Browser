import AppKit
import Foundation

/// Local crash note only. Nothing is uploaded.
enum CrashCenter {
    private static let stateName = "run-state.txt"
    private static let noteName = "crash-note.txt"
    private static var installed = false
    private static var cachedReport: String?

    static func prepareForLaunch() {
        cachedReport = pendingReport()
    }

    static func takeReport() -> String? {
        let report = cachedReport
        cachedReport = nil
        return report
    }

    static func install() {
        guard !installed else { return }
        installed = true
        if let url = try? JSONStore.url(noteName) {
            url.path.withCString { LumenInstallCrashNote($0) }
        }
        LumenInstallSignals()
        LumenInstallExceptionHandler()
    }

    static func markRunning() {
        writeState("running")
    }

    static func markClean() {
        writeState("clean")
    }

    static func interpret(state: String?) -> Bool {
        state == "running"
    }

    static func pendingReport() -> String? {
        let state = readState()
        let unclean = interpret(state: state)
        writeState("running")
        guard unclean else { return nil }
        var parts: [String] = []
        if let note = readNote(), !note.isEmpty {
            parts.append(note)
        }
        if let ips = latestDiagnosticReport() {
            parts.append(ips)
        } else {
            parts.append("No DiagnosticReports entry for this app was readable.")
        }
        let text = parts.joined(separator: "\n\n")
        clearNote()
        return String(text.prefix(48_000))
    }

    static func present(_ report: String) {
        let alert = NSAlert()
        alert.messageText = "Sathariels Browser quit unexpectedly"
        alert.informativeText = "The report stays on this Mac. Nothing is sent. Restore previous session keeps the saved tabs."
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        view.string = String(report.prefix(12_000))
        view.isEditable = false
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        alert.accessoryView = view
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Copy report")
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Reveal")
        alert.addButton(withTitle: "Restore session")
        while true {
            switch alert.runModal().rawValue {
            case NSApplication.ModalResponse.alertFirstButtonReturn.rawValue:
                return
            case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
                save(report)
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1:
                reveal()
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 2:
                SettingsStore.shared.restoreSession = true
                SessionRegistry.shared.keySession?.replaceFromSavedSession()
                return
            default:
                return
            }
        }
    }

    private static func save(_ report: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sathariels Browser crash.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static func reveal() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        if let latest = diagnosticURL() {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([home])
    }

    private static func writeState(_ value: String) {
        try? value.data(using: .utf8)?.write(to: (try? JSONStore.url(stateName)) ?? URL(fileURLWithPath: "/dev/null"), options: .atomic)
    }

    private static func readState() -> String? {
        guard let url = try? JSONStore.url(stateName), let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readNote() -> String? {
        guard let url = try? JSONStore.url(noteName), let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func clearNote() {
        if let url = try? JSONStore.url(noteName) {
            try? Data().write(to: url)
        }
    }

    private static func diagnosticURL() -> URL? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let matches = names.filter { $0.contains("Sathariels") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }
        let newest = matches.max { lhs, rhs in
            let left = (try? folder.appendingPathComponent(lhs).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? folder.appendingPathComponent(rhs).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        return newest.map { folder.appendingPathComponent($0) }
    }

    private static func latestDiagnosticReport() -> String? {
        guard let url = diagnosticURL(), let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data.prefix(32_000), encoding: .utf8) ?? ""
        return text.isEmpty ? nil : "DiagnosticReports/\(url.lastPathComponent)\n\(text)"
    }
}
