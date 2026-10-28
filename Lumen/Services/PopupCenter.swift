import AppKit
import ObjectiveC
import WebKit

final class PopupCenter: NSObject, NSWindowDelegate {
    private final class Box {
        let id = UUID()
        let webView: WKWebView
        let window: NSWindow
        let delegate: TabWebDelegate
        init(webView: WKWebView, window: NSWindow, delegate: TabWebDelegate) {
            self.webView = webView
            self.window = window
            self.delegate = delegate
        }
    }

    weak var session: BrowserSession?
    private var boxes: [UUID: Box] = [:]

    func open(configuration: WKWebViewConfiguration, features: WKWindowFeatures, capturePasswords: Bool) -> WKWebView {
        let width = features.width?.doubleValue ?? 480
        let height = features.height?.doubleValue ?? 720
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(320, width), height: max(240, height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lumen"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = LumenTheme.windowBackground
        window.isReleasedWhenClosed = false
        let delegate = TabWebDelegate()
        delegate.session = session
        let webView = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        WebKitFactory.attach(webView: webView, handler: delegate, capturePasswords: capturePasswords)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        window.contentView = webView
        window.center()
        let box = Box(webView: webView, window: window, delegate: delegate)
        boxes[box.id] = box
        window.delegate = self
        objc_setAssociatedObject(window, &popupKey, box.id.uuidString as NSString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        delegate.onClose = { [weak self, weak window] in
            window?.close()
            self?.drop(window)
        }
        window.makeKeyAndOrderFront(nil)
        return webView
    }

    func closeAll() {
        for box in boxes.values {
            WebKitFactory.detach(box.webView)
            box.window.delegate = nil
            box.window.close()
        }
        boxes.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        drop(window)
    }

    private func drop(_ window: NSWindow?) {
        guard let window,
              let token = objc_getAssociatedObject(window, &popupKey) as? NSString,
              let id = UUID(uuidString: token as String),
              let box = boxes.removeValue(forKey: id) else { return }
        WebKitFactory.detach(box.webView)
    }
}

private var popupKey: UInt8 = 0
