import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

struct DownloadRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var destination: String?
    var source: String?
    var bytesWritten: Int64
    var bytesExpected: Int64
    var state: DownloadState
    var detail: String?
    var hasResume: Bool
}

final class DownloadController: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadController()

    @Published private(set) var rows: [DownloadRow] = []
    private var downloads: [UUID: WKDownload] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var idByObject: [ObjectIdentifier: UUID] = [:]
    private var samples: [UUID: (date: Date, bytes: Int64)] = [:]
    private let listName = "downloads.json"

    var hasActive: Bool { rows.contains { $0.state == .active } }
    var activeFraction: Double? {
        let active = rows.filter { $0.state == .active }
        guard !active.isEmpty else { return nil }
        let known = active.compactMap(\.fraction)
        guard !known.isEmpty else { return 0.05 }
        return known.reduce(0, +) / Double(known.count)
    }

    private override init() {
        super.init()
        rows = Self.loadRecords().map(Self.row(from:))
    }

    func isDownloading(_ tabID: UUID) -> Bool {
        rows.contains { $0.tabID == tabID && $0.state == .active }
    }

    func accept(_ download: WKDownload, tabID: UUID?) {
        let id = UUID()
        attach(download, id: id, filename: "Download", source: download.originalRequest?.url?.absoluteString, tabID: tabID, state: .active)
    }

    func pause(_ id: UUID) {
        guard let download = downloads[id] else { return }
        download.cancel { [weak self] data in
            DispatchQueue.main.async {
                self?.keepResume(id, data: data)
                self?.mark(id, state: .paused, detail: "Paused")
                self?.release(id, deletePartial: false)
            }
        }
    }

    func resume(_ id: UUID) {
        guard let data = resumeData(id), let webView = SessionRegistry.shared.keySession?.focusedTab?.webView else { return }
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            DispatchQueue.main.async {
                guard let self else { return }
                let row = self.rows.first { $0.id == id }
                self.attach(download, id: id, filename: row?.filename ?? "Download", source: row?.source, tabID: row?.tabID, state: .active)
            }
        }
    }

    func retry(_ id: UUID) {
        guard let source = rows.first(where: { $0.id == id })?.source, let url = URL(string: source),
              let webView = SessionRegistry.shared.keySession?.focusedTab?.webView else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            DispatchQueue.main.async {
                self?.accept(download, tabID: nil)
            }
        }
    }

    func cancel(_ id: UUID) {
        downloads[id]?.cancel(nil)
        mark(id, state: .cancelled, detail: "Cancelled")
        deleteResume(id)
        release(id, deletePartial: true)
    }

    func open(_ id: UUID) {
        guard let url = rows.first(where: { $0.id == id })?.destination else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ id: UUID) {
        guard let url = rows.first(where: { $0.id == id })?.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearFinished() {
        let finished = rows.filter { $0.state != .active }
        for row in finished {
            deleteResume(row.id)
            release(row.id, deletePartial: false)
        }
        rows.removeAll { $0.state != .active }
        persist()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let filename = Self.safeFilename(suggestedFilename.isEmpty ? (response.suggestedFilename ?? "download") : suggestedFilename)
        let choose = SettingsStore.shared.downloadAskWhere
        DispatchQueue.main.async {
            let destination: URL?
            if choose {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = filename
                panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                destination = panel.runModal() == .OK ? panel.url : nil
            } else if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                destination = Self.uniqueURL(folder.appendingPathComponent(filename))
            } else {
                destination = nil
            }
            if let destination, let id = self.idByObject[ObjectIdentifier(download)], let index = self.rows.firstIndex(where: { $0.id == id }) {
                self.rows[index].filename = destination.lastPathComponent
                self.rows[index].destination = destination
                self.persist()
            }
            completionHandler(destination)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        DispatchQueue.main.async {
            guard let id = self.idByObject[ObjectIdentifier(download)] else { return }
            self.deleteResume(id)
            self.mark(id, state: .finished, detail: nil)
            self.release(id, deletePartial: false)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async {
            guard let id = self.idByObject[ObjectIdentifier(download)] else { return }
            self.keepResume(id, data: resumeData)
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                if self.rows.first(where: { $0.id == id })?.state != .paused {
                    self.mark(id, state: .cancelled, detail: "Cancelled")
                }
            } else {
                self.mark(id, state: .failed, detail: ns.localizedDescription)
            }
            self.release(id, deletePartial: resumeData == nil)
        }
    }

    private func attach(_ download: WKDownload, id: UUID, filename: String, source: String?, tabID: UUID?, state: DownloadState) {
        download.delegate = self
        downloads[id] = download
        idByObject[ObjectIdentifier(download)] = id
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].state = state
            rows[index].detail = nil
        } else {
            rows.insert(DownloadRow(
                id: id, filename: filename, destination: nil, source: source,
                bytesWritten: 0, bytesExpected: 0, fraction: nil, bytesPerSecond: 0,
                state: state, detail: nil, tabID: tabID
            ), at: 0)
        }
        observations[id]?.invalidate()
        observations[id] = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async { self?.noteProgress(id: id, progress: progress) }
        }
        persist()
    }

    private func noteProgress(id: UUID, progress: Progress) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        let written = progress.completedUnitCount
        if let sample = samples[id] {
            let delta = now.timeIntervalSince(sample.date)
            if delta >= 0.5 {
                rows[index].bytesPerSecond = Double(written - sample.bytes) / delta
                samples[id] = (now, written)
            }
        } else {
            samples[id] = (now, written)
        }
        rows[index].fraction = progress.fractionCompleted
        rows[index].bytesWritten = written
        rows[index].bytesExpected = progress.totalUnitCount
    }

    private func mark(_ id: UUID, state: DownloadState, detail: String?) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
        rows[index].detail = detail
        if state == .finished { rows[index].fraction = 1 }
        persist()
    }

    private func release(_ id: UUID, deletePartial: Bool) {
        observations[id]?.invalidate()
        observations[id] = nil
        samples[id] = nil
        if let download = downloads.removeValue(forKey: id) {
            idByObject.removeValue(forKey: ObjectIdentifier(download))
        }
        if deletePartial, let url = rows.first(where: { $0.id == id })?.destination {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func keepResume(_ id: UUID, data: Data?) {
        guard let data, !data.isEmpty, data.count < 8_000_000, let url = try? JSONStore.url("resume-\(id.uuidString).bin") else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func resumeData(_ id: UUID) -> Data? {
        guard let url = try? JSONStore.url("resume-\(id.uuidString).bin") else { return nil }
        return try? Data(contentsOf: url)
    }

    private func deleteResume(_ id: UUID) {
        JSONStore.remove("resume-\(id.uuidString).bin")
    }

    private func persist() {
        let records = rows.prefix(40).map { row in
            DownloadRecord(
                id: row.id, filename: row.filename, destination: row.destination?.path,
                source: row.source, bytesWritten: row.bytesWritten, bytesExpected: row.bytesExpected,
                state: row.state == .active ? .paused : row.state, detail: row.detail,
                hasResume: resumeDataExists(row.id)
            )
        }
        JSONStore.save(Array(records), as: listName)
    }

    private func resumeDataExists(_ id: UUID) -> Bool {
        guard let url = try? JSONStore.url("resume-\(id.uuidString).bin") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func loadRecords() -> [DownloadRecord] {
        JSONStore.load("downloads.json", as: [DownloadRecord].self) ?? []
    }

    private static func row(from record: DownloadRecord) -> DownloadRow {
        DownloadRow(
            id: record.id, filename: record.filename,
            destination: record.destination.map { URL(fileURLWithPath: $0) },
            source: record.source, bytesWritten: record.bytesWritten, bytesExpected: record.bytesExpected,
            fraction: record.state == .finished ? 1 : nil, bytesPerSecond: 0,
            state: record.state == .active ? .paused : record.state,
            detail: record.detail, tabID: nil
        )
    }

    static func safeFilename(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "download" }
        return cleaned
    }

    static func uniqueURL(_ url: URL) -> URL {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
