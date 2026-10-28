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
            addRuleList(ruleList, to: controller)
        }
        if let site {
            addUserScript(WKUserScript(
                source: PageScripts.permissionSource(site),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ), to: controller)
        }
        addUserScript(WKUserScript(
            source: PageScripts.editedPageWatcher,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ), to: controller)
        addUserScript(WKUserScript(
            source: PageScripts.findEngine,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ), to: controller)
        if capturePasswords {
            addUserScript(WKUserScript(
                source: PageScripts.passwordWatcher,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ), to: controller)
        }
        if pageGhost {
            addUserScript(WKUserScript(
                source: PageScripts.fieldGhost,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ), to: controller)
        }
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        ExtensionSupport.attach(configuration)
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
        registerHandlers(on: webView, handler: handler, capturePasswords: capturePasswords, pageGhost: pageGhost)
    }

    /// Names already registered on this controller. A popup shares the opener's controller,
    /// so a second add of the same name throws and aborts the process.
    static func installedHandlerNames(for controller: WKUserContentController) -> Set<String> {
        ControllerUses.use(for: controller).handlerNames
    }

    static func detach(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let controller = webView.configuration.userContentController
        let attached = objc_getAssociatedObject(webView, &attachedKey) != nil
        objc_setAssociatedObject(webView, &attachedKey, nil, .OBJC_ASSOCIATION_ASSIGN)
        webView.removeFromSuperview()
        guard attached else { return }
        let use = ControllerUses.use(for: controller)
        use.owners = max(0, use.owners - 1)
        // Other web views, including the opener, still need the scripts, rules, and handlers.
        guard use.owners == 0 else { return }
        for name in use.handlerNames {
            controller.removeScriptMessageHandler(forName: name)
        }
        use.handlerNames.removeAll()
        use.proxy = nil
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        use.ruleIDs.removeAll()
    }

    private static func registerHandlers(
        on webView: WKWebView,
        handler: WKScriptMessageHandler,
        capturePasswords: Bool,
        pageGhost: Bool
    ) {
        if objc_getAssociatedObject(webView, &attachedKey) != nil { return }
        objc_setAssociatedObject(webView, &attachedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let controller = webView.configuration.userContentController
        let use = ControllerUses.use(for: controller)
        use.owners += 1
        // Private windows skip the bridge. Google treats an empty message handler as a web view.
        guard capturePasswords || pageGhost else { return }
        if use.proxy == nil {
            use.proxy = WeakScriptProxy(target: handler)
        }
        guard let proxy = use.proxy else { return }
        if capturePasswords { addHandler(proxy, name: "lumenPassword", controller: controller, use: use) }
        if pageGhost { addHandler(proxy, name: "lumenGhost", controller: controller, use: use) }
    }

    private static func addHandler(_ proxy: WeakScriptProxy, name: String, controller: WKUserContentController, use: ControllerUse) {
        guard !use.handlerNames.contains(name) else { return }
        controller.add(proxy, name: name)
        use.handlerNames.insert(name)
    }

    private static func addRuleList(_ list: WKContentRuleList, to controller: WKUserContentController) {
        let use = ControllerUses.use(for: controller)
        guard use.ruleIDs.insert(list.identifier).inserted else { return }
        controller.add(list)
    }

    private static func addUserScript(_ script: WKUserScript, to controller: WKUserContentController) {
        let already = controller.userScripts.contains { existing in
            existing.source == script.source
                && existing.injectionTime == script.injectionTime
                && existing.isForMainFrameOnly == script.isForMainFrameOnly
        }
        if already { return }
        controller.addUserScript(script)
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

private var attachedKey: UInt8 = 0
private var controllerUseKey: UInt8 = 0

private final class ControllerUse: NSObject {
    var owners = 0
    var handlerNames = Set<String>()
    var ruleIDs = Set<String>()
    var proxy: WeakScriptProxy?
}

private enum ControllerUses {
    static func use(for controller: WKUserContentController) -> ControllerUse {
        if let existing = objc_getAssociatedObject(controller, &controllerUseKey) as? ControllerUse {
            return existing
        }
        let created = ControllerUse()
        objc_setAssociatedObject(controller, &controllerUseKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return created
    }
}

final class WeakScriptProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
