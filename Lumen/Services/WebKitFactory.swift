import Darwin
import Foundation
import ObjectiveC
import WebKit

/// One pool for ordinary windows. WebKit deprecated WKProcessPool because the
/// system pool is shared already; setting one instance keeps older systems on a single pool.
enum WebKitPool {
    static let shared: WKProcessPool = WKProcessPool()
}

enum SystemAutoFill {
    /// Public WKWebView cannot read Safari's iCloud Passwords for arbitrary sites.
    /// If this OS still exposes the private setter, turn it on. A missing selector is ignored.
    static func enableIfAvailable(on preferences: WKPreferences) {
        let selector = NSSelectorFromString("_setPasswordAutoFillEnabled:")
        guard preferences.responds(to: selector) else { return }
        typealias Send = @convention(c) (AnyObject, Selector, Bool) -> Void
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend") else { return }
        let send = unsafeBitCast(symbol, to: Send.self)
        send(preferences, selector, true)
    }
}

enum WebKitFactory {
    static func configuration(
        dataStore: WKWebsiteDataStore,
        processPool: WKProcessPool,
        site: SitePermissions?,
        ruleLists: [WKContentRuleList],
        capturePasswords: Bool,
        pageGhost: Bool = false
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        SystemAutoFill.enableIfAvailable(on: configuration.preferences)
        let allowsAutoplay = site?.autoplay == .allow
        configuration.mediaTypesRequiringUserActionForPlayback = allowsAutoplay ? [] : .all

        let controller = WKUserContentController()
        for ruleList in ruleLists {
            controller.add(ruleList)
        }
        if let site {
            let permissions = WKUserScript(
                source: PageScripts.permissionSource(site),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            controller.addUserScript(permissions)
        }
        controller.addUserScript(WKUserScript(
            source: PageScripts.editedPageWatcher,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: PageScripts.findEngine,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        if capturePasswords {
            controller.addUserScript(WKUserScript(
                source: PageScripts.passwordWatcher,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        if pageGhost {
            controller.addUserScript(WKUserScript(
                source: PageScripts.fieldGhost,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    static func attach(
        webView: WKWebView,
        handler: WKScriptMessageHandler,
        capturePasswords: Bool,
        pageGhost: Bool = false
    ) {
        webView.customUserAgent = SafariUserAgent.current
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        // Register the bridge only when we need it. An empty WKWebView bridge is one of
        // the signals Google uses to refuse sign-in, so private windows skip it.
        var names: [String] = []
        if capturePasswords || pageGhost {
            let proxy = WeakScriptProxy(target: handler)
            if capturePasswords {
                webView.configuration.userContentController.add(proxy, name: "lumenPassword")
                names.append("lumenPassword")
            }
            if pageGhost {
                webView.configuration.userContentController.add(proxy, name: "lumenGhost")
                names.append("lumenGhost")
            }
            objc_setAssociatedObject(webView, &proxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(webView, &handlerNamesKey, names as NSArray, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    static func detach(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let controller = webView.configuration.userContentController
        let names = objc_getAssociatedObject(webView, &handlerNamesKey) as? [String] ?? []
        for name in names {
            controller.removeScriptMessageHandler(forName: name)
        }
        controller.removeAllScriptMessageHandlers()
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        webView.removeFromSuperview()
        objc_setAssociatedObject(webView, &proxyKey, nil, .OBJC_ASSOCIATION_ASSIGN)
        objc_setAssociatedObject(webView, &handlerNamesKey, nil, .OBJC_ASSOCIATION_ASSIGN)
    }
}

enum WebInspector {
    static func show(_ webView: WKWebView) {
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        let show = NSSelectorFromString("_showInspector:")
        if webView.responds(to: show) {
            webView.perform(show, with: nil)
            return
        }
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter),
              let unmanaged = webView.perform(getter),
              let inspector = unmanaged.takeUnretainedValue() as? NSObject else { return }
        let reveal = NSSelectorFromString("show")
        if inspector.responds(to: reveal) {
            inspector.perform(reveal)
        }
    }
}

private var proxyKey: UInt8 = 0
private var handlerNamesKey: UInt8 = 0

final class WeakScriptProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
