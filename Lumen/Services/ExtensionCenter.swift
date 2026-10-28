import AppKit
import Foundation
import WebKit

/// Loads unpacked web extension folders on macOS 15.4 and later.
/// Extensions installed inside Safari or other apps are not visible to this process.
enum ExtensionSupport {
    static var isAvailable: Bool {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *) { return true }
        #endif
        return false
    }

    static func pickFolder() {
        #if compiler(>=6.1)
        guard #available(macOS 15.4, *) else { return }
        ExtensionCenter.shared.pickAndLoad()
        #endif
    }

    static func restoreSaved() {
        #if compiler(>=6.1)
        guard #available(macOS 15.4, *) else { return }
        ExtensionCenter.shared.restoreSaved()
        #endif
    }

    static func attach(_ configuration: WKWebViewConfiguration) {
        #if compiler(>=6.1)
        guard #available(macOS 15.4, *) else { return }
        // A popup configuration already carries the opener's controller. Assigning another one is unnecessary.
        if configuration.webExtensionController == nil {
            configuration.webExtensionController = ExtensionCenter.shared.controller
        }
        #endif
    }
}

final class ExtensionMenuModel: ObservableObject {
    static let shared = ExtensionMenuModel()
    @Published var names: [String] = []
    var available: Bool { ExtensionSupport.isAvailable }
    private init() {}
}

// These types first shipped in the Xcode 16.3 SDK. Runtime checks alone
// cannot make older compilers resolve them.
#if compiler(>=6.1)
@available(macOS 15.4, *)
final class ExtensionCenter: NSObject {
    static let shared = ExtensionCenter()
    let controller = WKWebExtensionController()
    private var bookmarks: [Data] = []
    private let defaultsKey = "extensionBookmarks"

    private override init() {
        super.init()
        bookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
    }

    func pickAndLoad() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Load"
        panel.message = "Choose a folder that contains a web extension manifest.json."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url: url, remember: true)
        }
    }

    func restoreSaved() {
        for data in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            load(url: url, remember: false)
        }
    }

    private func load(url: URL, remember: Bool) {
        let accessing = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let manifest = url.appendingPathComponent("manifest.json")
                guard FileManager.default.fileExists(atPath: manifest.path) else { return }
                let extensionObject = try await WKWebExtension(resourceBaseURL: url)
                let context = WKWebExtensionContext(for: extensionObject)
                try controller.load(context)
                let name = url.lastPathComponent
                if !ExtensionMenuModel.shared.names.contains(name) {
                    ExtensionMenuModel.shared.names.append(name)
                }
                if remember, let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    bookmarks.append(data)
                    if bookmarks.count > 16 { bookmarks.removeFirst(bookmarks.count - 16) }
                    UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
                }
            } catch {
                ExtensionMenuModel.shared.names.append("Could not load \(url.lastPathComponent)")
            }
        }
    }
}

#endif
