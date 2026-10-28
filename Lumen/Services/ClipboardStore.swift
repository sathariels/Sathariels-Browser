import AppKit
import Foundation

final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    static let cap = 60

    @Published private(set) var items: [ClipItem] = []
    private var timer: Timer?
    private var lastChange: Int
    private var captureEnabled: Bool
    private let cache = NSCache<NSString, NSImage>()
    private let echoType = NSPasteboard.PasteboardType("app.lumen.browser.echo")
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private init() {
        lastChange = NSPasteboard.general.changeCount
        captureEnabled = SettingsStore.shared.clipboardCapture
        items = JSONStore.load("clipboard.json", as: [ClipItem].self) ?? []
        cache.countLimit = 8
        if captureEnabled { startTimer() }
    }

    func setCaptureEnabled(_ enabled: Bool) {
        captureEnabled = enabled
        if enabled { startTimer() } else { timer?.invalidate(); timer = nil }
    }

    func thumbnail(for item: ClipItem) -> NSImage? {
        guard item.kind == .image, let name = item.thumbFile else { return nil }
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = try? JSONStore.directory().appendingPathComponent("clipboard-thumbs", isDirectory: true).appendingPathComponent(name),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func dropThumbnails() {
        cache.removeAllObjects()
    }

    func copy(_ item: ClipItem) {
        let board = NSPasteboard.general
        board.clearContents()
        switch item.kind {
        case .text, .url:
            board.setString(item.text ?? "", forType: .string)
        case .image:
            if let image = thumbnail(for: item) {
                board.writeObjects([image])
            }
        }
        board.setData(Data([1]), forType: echoType)
        lastChange = board.changeCount
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        persist()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        removeThumb(items[index])
        items.remove(at: index)
        persist()
    }

    func clearUnpinned() {
        let removed = items.filter { !$0.pinned }
        removed.forEach(removeThumb)
        items.removeAll { !$0.pinned }
        persist()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard captureEnabled, NSApp.isActive else { return }
        if SessionRegistry.shared.keyWindowIsPrivate { return }
        let board = NSPasteboard.general
        let change = board.changeCount
        guard change != lastChange else { return }
        lastChange = change
        ingest(board)
    }

    private func ingest(_ board: NSPasteboard) {
        let types = board.types ?? []
        if types.contains(concealed) || types.contains(transient) || types.contains(echoType) {
            return
        }
        if let image = board.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           board.string(forType: .string) == nil {
            storeImage(image)
            return
        }
        if let string = board.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let clipped = String(trimmed.prefix(4_000))
            if let url = URL(string: clipped), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", clipped.count < 2_000 {
                push(ClipItem(id: UUID(), kind: .url, text: clipped, created: Date(), pinned: false, thumbFile: nil))
            } else {
                push(ClipItem(id: UUID(), kind: .text, text: clipped, created: Date(), pinned: false, thumbFile: nil))
            }
        }
    }

    private func storeImage(_ image: NSImage) {
        guard let data = Self.thumbnailJPEG(image) else { return }
        let name = UUID().uuidString + ".jpg"
        do {
            let dir = try JSONStore.directory().appendingPathComponent("clipboard-thumbs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            push(ClipItem(id: UUID(), kind: .image, text: "Image", created: Date(), pinned: false, thumbFile: name))
        } catch {
            return
        }
    }

    private func push(_ item: ClipItem) {
        if let text = item.text, items.first?.text == text, items.first?.kind == item.kind { return }
        items.insert(item, at: 0)
        let pinned = items.filter(\.pinned)
        var loose = items.filter { !$0.pinned }
        if loose.count > Self.cap {
            loose.suffix(loose.count - Self.cap).forEach(removeThumb)
            loose = Array(loose.prefix(Self.cap))
        }
        items = pinned + loose
        persist()
    }

    private func persist() {
        JSONStore.save(items, as: "clipboard.json")
    }

    private func removeThumb(_ item: ClipItem) {
        guard let name = item.thumbFile,
              let url = try? JSONStore.directory().appendingPathComponent("clipboard-thumbs/\(name)") else { return }
        try? FileManager.default.removeItem(at: url)
        cache.removeObject(forKey: name as NSString)
    }

    private static func thumbnailJPEG(_ image: NSImage) -> Data? {
        let side: CGFloat = 48
        let target = NSSize(width: side, height: side)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: target).fill()
        let source = image.size
        let scale = min(side / max(source.width, 1), side / max(source.height, 1))
        let draw = NSSize(width: source.width * scale, height: source.height * scale)
        let origin = NSPoint(x: (side - draw.width) / 2, y: (side - draw.height) / 2)
        image.draw(in: NSRect(origin: origin, size: draw), from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        guard let tiff = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.45])
    }
}
