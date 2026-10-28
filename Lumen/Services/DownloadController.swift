import AppKit
import Foundation
import WebKit

final class DownloadController: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadController()

    @Published private(set) var rows: [DownloadRow] = []
    private var downloads: [UUID: WKDownload] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var idByObject: [ObjectIdentifier: UUID] = [:]

    func isDownloading(_ tabID: UUID) -> Bool {
        rows.contains { $0.tabID == tabID && $0.state == .active }
    }

    var hasActive: Bool { rows.contains { $0.state == .active } }

    func accept(_ download: WKDownload, tabID: UUID?) {
        let id = UUID()
        download.delegate = self
        downloads[id] = download
        idByObject[ObjectIdentifier(download)] = id
        rows.insert(DownloadRow(
            id: id,
            filename: "Download",
            destination: nil,
            bytesWritten: 0,
            bytesExpected: 0,
            fraction: nil,
            state: .active,
            detail: nil,
            tabID: tabID
        ), at: 0)
        observations[id] = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.noteProgress(id: id, progress: progress)
            }
        }
    }

    func cancel(_ id: UUID) {
        downloads[id]?.cancel(nil)
        mark(id, state: .cancelled, detail: "Cancelled")
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
            release(row.id, deletePartial: false)
        }
        rows.removeAll { $0.state != .active }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let filename = Self.safeFilename(suggestedFilename.isEmpty ? (response.suggestedFilename ?? "download") : suggestedFilename)
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            completionHandler(nil)
            return
        }
        let destination = Self.uniqueURL(folder.appendingPathComponent(filename))
        let id = idByObject[ObjectIdentifier(download)]
        DispatchQueue.main.async {
            if let id, let index = self.rows.firstIndex(where: { $0.id == id }) {
                self.rows[index].filename = destination.lastPathComponent
                self.rows[index].destination = destination
            }
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        DispatchQueue.main.async {
            guard let id = self.idByObject[ObjectIdentifier(download)] else { return }
            self.mark(id, state: .finished, detail: nil)
            self.release(id, deletePartial: false)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async {
            guard let id = self.idByObject[ObjectIdentifier(download)] else { return }
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                self.mark(id, state: .cancelled, detail: "Cancelled")
            } else {
                self.mark(id, state: .failed, detail: ns.localizedDescription)
            }
            self.release(id, deletePartial: true)
        }
    }

    private func noteProgress(id: UUID, progress: Progress) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].fraction = progress.fractionCompleted
        rows[index].bytesWritten = progress.completedUnitCount
        rows[index].bytesExpected = progress.totalUnitCount
    }

    private func mark(_ id: UUID, state: DownloadState, detail: String?) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
        rows[index].detail = detail
        if state == .finished { rows[index].fraction = 1 }
    }

    private func release(_ id: UUID, deletePartial: Bool) {
        observations[id]?.invalidate()
        observations[id] = nil
        if let download = downloads.removeValue(forKey: id) {
            idByObject.removeValue(forKey: ObjectIdentifier(download))
        }
        if deletePartial, let url = rows.first(where: { $0.id == id })?.destination {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func safeFilename(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "download" }
        return cleaned
    }

    private static func uniqueURL(_ url: URL) -> URL {
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
