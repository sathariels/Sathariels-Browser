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
        ruleList: WKContentRuleList?,
        blockingEnabled: Bool,
        capturePasswords: Bool
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        SystemAutoFill.enableIfAvailable(on: configuration.preferences)
        let allowsAutoplay = site?.autoplay == .allow
        configuration.mediaTypesRequiringUserActionForPlayback = allowsAutoplay ? [] : .all

        let controller = WKUserContentController()
        if blockingEnabled, let ruleList {
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
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    static func attach(
        webView: WKWebView,
        handler: WKScriptMessageHandler,
        capturePasswords: Bool
    ) {
        webView.customUserAgent = SafariUserAgent.current
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) {
            #if DEBUG
            webView.isInspectable = true
            #else
            webView.isInspectable = false
            #endif
        }
        // Register the bridge only when we need it. An empty WKWebView bridge is one of
        // the signals Google uses to refuse sign-in, so private windows skip it.
        guard capturePasswords else { return }
        let proxy = WeakScriptProxy(target: handler)
        webView.configuration.userContentController.add(proxy, name: "lumenPassword")
        objc_setAssociatedObject(webView, &proxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func detach(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lumenPassword")
        webView.configuration.userContentController.removeAllUserScripts()
        webView.removeFromSuperview()
        objc_setAssociatedObject(webView, &proxyKey, nil, .OBJC_ASSOCIATION_ASSIGN)
    }
}

private var proxyKey: UInt8 = 0

final class WeakScriptProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
