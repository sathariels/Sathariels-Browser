import AppKit
import AuthenticationServices
import Foundation
import WebKit

final class TabWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    weak var session: BrowserSession?
    var onClose: (() -> Void)?
    private var promptedPassword = Set<String>()
    private var offeredGoogleFallback = false

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "lumenMedia" {
            handleMedia(message)
            return
        }
        if message.name == "lumenGhost" {
            handleGhost(message)
            return
        }
        guard message.name == "lumenPassword", session?.isPrivate != true else { return }
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              [0, 443].contains(message.frameInfo.securityOrigin.port),
              let pageHost = PasswordPage.host(message.webView?.url),
              pageHost == message.frameInfo.securityOrigin.host.lowercased() else { return }
        guard let body = message.body as? [String: Any] else { return }
        let username = String((body["username"] as? String ?? "").prefix(256))
        let password = String((body["password"] as? String ?? "").prefix(1024))
        guard !password.isEmpty else { return }
        let host = message.frameInfo.securityOrigin.host.lowercased()
        guard !host.isEmpty else { return }
        if SettingsStore.shared.neverSavePasswords(for: host) { return }
        let key = host + "\n" + username
        if promptedPassword.contains(key) { return }
        promptedPassword.insert(key)
        let result = PasswordPrompt.ask(host: host, username: username)
        switch result {
        case .save:
            _ = PasswordVault.save(host: host, username: username, password: password)
        case .never:
            SettingsStore.shared.blockPasswordSaves(for: host)
        case .later:
            break
        }
    }

    private func handleMedia(_ message: WKScriptMessage) {
        guard let tab, message.webView == nil || message.webView === tab.webView else { return }
        let body = message.body as? [String: Any]
        let playing = body?["playing"] as? Bool ?? false
        let audible = body?["audible"] as? Bool ?? false
        tab.playing = playing
        tab.audible = audible && !tab.muted
    }

    private func handleGhost(_ message: WKScriptMessage) {
        guard SettingsStore.shared.pageFieldGhost, session?.isPrivate != true else { return }
        guard let body = message.body as? [String: Any], let webView = message.webView else { return }
        let requestID: Int
        if let number = body["id"] as? Int {
            requestID = number
        } else if let number = body["id"] as? NSNumber {
            requestID = number.intValue
        } else {
            return
        }
        let prefix = String((body["prefix"] as? String ?? "").prefix(180))
        let label = String((body["label"] as? String ?? "").prefix(80))
        guard prefix.count >= 2 else { return }
        let token = GhostCompletion.bumpField()
        Task { @MainActor [weak webView] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard webView != nil, GhostCompletion.fieldIsCurrent(token) else { return }
            let full = await GhostCompletion.field(prefix: prefix, label: label)
            guard let webView, GhostCompletion.fieldIsCurrent(token) else { return }
            let suffix = full.flatMap { Omnibox.completionSuffix(typed: prefix, suggestion: $0) } ?? ""
            let script = "window.__lumenGhost && window.__lumenGhost.show(\(requestID), \(JSEncode.string(suffix)))"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        if main, scheme == "http" || scheme == "https" {
            switch navigationChoice(for: url, action: navigationAction) {
            case .allow:
                tab?.pageWarning = nil
                decisionHandler(.allow, preferences)
            case .load(let next):
                tab?.pageWarning = nil
                decisionHandler(.cancel, preferences)
                webView.load(URLRequest(url: next))
            case .warn(let warning):
                if case .unsafe = warning { tab?.httpsUpgradeURL = nil }
                tab?.pageWarning = warning
                decisionHandler(.cancel, preferences)
            }
            return
        }
        switch scheme {
        case "http", "https", "about", "file", "blob", "data":
            decisionHandler(.allow, preferences)
        default:
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel, preferences)
        }
    }

    private enum NavigationChoice {
        case allow
        case load(URL)
        case warn(PageWarning)
    }

    private func navigationChoice(for url: URL, action: WKNavigationAction) -> NavigationChoice {
        let method = action.request.httpMethod?.uppercased() ?? "GET"
        let settings = SettingsStore.shared
        if settings.safeBrowsing, tab?.threatBypass.contains(url.absoluteString) != true, ThreatList.shared.contains(url) {
            return .warn(.unsafe(url))
        }
        // Do not rewrite or replay POST bodies, but still apply threat checks above.
        guard method == "GET" || method == "HEAD" else { return .allow }
        let current = url
        if settings.stripTracking, let stripped = TrackingStrip.stripped(current), stripped.absoluteString != current.absoluteString {
            return .load(stripped)
        }
        if settings.httpsOnly, current.scheme?.lowercased() == "http", !HTTPSOnly.isExempt(host: current.host) {
            if tab?.httpBypass.contains(current.absoluteString) == true {
                return .allow
            }
            if let pending = tab?.httpsUpgradeURL, pending.host?.lowercased() == current.host?.lowercased() {
                return .warn(.httpsFailed(pending))
            }
            if let https = HTTPSOnly.upgraded(current) {
                tab?.httpsUpgradeURL = current
                return .load(https)
            }
        }
        if settings.safeBrowsing, tab?.threatBypass.contains(current.absoluteString) != true, ThreatList.shared.contains(current) {
            return .warn(.unsafe(current))
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        let url = navigationResponse.response.url
        if navigationResponse.isForMainFrame {
            tab?.lastMIME = mime
            if JSONSniffer.shouldIntercept(mime: mime, url: url), let url {
                decisionHandler(.cancel)
                tab?.loadJSON(from: url)
                return
            }
        }
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadController.shared.accept(download, tabID: tab?.id)
        session?.downloadsVisible = true
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadController.shared.accept(download, tabID: tab?.id)
        session?.downloadsVisible = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url, url.absoluteString != "about:blank" else { return }
        tab?.httpsUpgradeURL = nil
        tab?.pageWarning = nil
        tab?.url = url
        tab?.errorText = nil
        tab?.applyRememberedZoom(in: webView)
        session?.persist()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab else { return }
        if let url = webView.url, url.scheme != "about" {
            tab.url = url
            if let title = webView.title, !title.isEmpty { tab.title = title }
            if session?.isPrivate != true {
                HistoryStore.shared.record(url: url, title: tab.title)
            }
            tab.loadFavicon()
            tab.restoreScroll(in: webView)
            sniffJSON(url: url, webView: webView)
            noteGoogle(url: url, webView: webView)
            tab.considerPasswordFill()
        }
        session?.persist()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        note(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        note(error)
    }

    func webViewDidClose(_ webView: WKWebView) {
        onClose?()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let session else { return nil }
        // Permission belongs to the opener, not the destination it chooses.
        let host = navigationAction.sourceFrame.securityOrigin.host.lowercased()
        if !host.isEmpty {
            switch session.permissions.choice(host: host, kind: .popups) {
            case .deny:
                return nil
            case .ask:
                let allow = SitePrompt.ask(
                    title: "Pop-up from \(host)",
                    message: "Allow this site to open windows? Sathariels Browser remembers the choice."
                )
                session.permissions.set(host: host, kind: .popups, choice: allow ? .allow : .deny)
                if !allow { return nil }
            case .allow:
                break
            }
        }
        let sized = windowFeatures.width != nil || windowFeatures.height != nil
        if sized {
            return session.popups.open(
                configuration: configuration,
                features: windowFeatures,
                capturePasswords: !session.isPrivate,
                pageGhost: SettingsStore.shared.pageFieldGhost && !session.isPrivate
            )
        }
        return session.adoptExternalTab(configuration: configuration)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host.lowercased()
        guard let session, !host.isEmpty else {
            decisionHandler(.deny)
            return
        }
        switch type {
        case .camera:
            decisionHandler(resolve(host: host, kind: .camera, session: session))
        case .microphone:
            decisionHandler(resolve(host: host, kind: .microphone, session: session))
        case .cameraAndMicrophone:
            let camera = resolve(host: host, kind: .camera, session: session)
            if camera == .deny {
                session.permissions.set(host: host, kind: .microphone, choice: .deny)
                decisionHandler(.deny)
                return
            }
            let mic = resolve(host: host, kind: .microphone, session: session)
            decisionHandler(mic == .grant && camera == .grant ? .grant : .deny)
        @unknown default:
            decisionHandler(.deny)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = String(message.prefix(2_000))
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = String(message.prefix(2_000))
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = String(prompt.prefix(2_000))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func resolve(host: String, kind: PermissionKind, session: BrowserSession) -> WKPermissionDecision {
        switch session.permissions.choice(host: host, kind: kind) {
        case .allow:
            return .grant
        case .deny:
            return .deny
        case .ask:
            let allow = SitePrompt.ask(
                title: "\(host) wants the \(kind.label.lowercased())",
                message: "Sathariels Browser will remember this for \(host)."
            )
            session.permissions.set(host: host, kind: kind, choice: allow ? .allow : .deny)
            return allow ? .grant : .deny
        }
    }

    private func sniffJSON(url: URL, webView: WKWebView) {
        guard let tab, tab.jsonDocument == nil, JSONSniffer.shouldSniff(mime: tab.lastMIME, url: url) else { return }
        webView.evaluateJavaScript("(document.body && document.body.innerText) ? document.body.innerText.slice(0, 240) : ''") { [weak tab, weak webView] sample, _ in
            guard let webView, let tab, tab.webView === webView else { return }
            let text = sample as? String ?? ""
            guard JSONSniffer.looksLikeJSON(text) else { return }
            webView.evaluateJavaScript("(document.body && document.body.innerText) ? document.body.innerText.slice(0, \(JSONSniffer.byteCap)) : ''") { [weak tab, weak webView] full, _ in
                guard let raw = full as? String, let document = JSONDocument(raw: raw) else { return }
                DispatchQueue.main.async {
                    guard let webView, let tab, tab.webView === webView else { return }
                    tab.jsonDocument = document
                    if webView.canGoBack == false {
                        tab.releaseWebView()
                        tab.lifecycle = .suspended
                        tab.memory = .suspended
                    }
                }
            }
        }
    }

    private func noteGoogle(url: URL, webView: WKWebView) {
        if GoogleSignInDetector.isRejection(url: url) {
            tab?.googleBlocked = true
            offerGoogle(url: url)
            return
        }
        guard GoogleSignInDetector.isAccountsHost(url.host) else {
            tab?.googleBlocked = false
            return
        }
        webView.evaluateJavaScript(PageScripts.rejectionText) { [weak self] result, _ in
            let text = result as? String ?? ""
            if GoogleSignInDetector.isRejection(url: url, pageText: text) {
                self?.tab?.googleBlocked = true
                self?.offerGoogle(url: url)
            }
        }
    }

    private func offerGoogle(url: URL) {
        guard !offeredGoogleFallback else { return }
        offeredGoogleFallback = true
        if tab == nil {
            let alert = NSAlert()
            alert.messageText = "Google blocked this sign-in"
            alert.informativeText = "Sathariels Browser can open a system sign-in window. That window uses Safari's session and does not copy cookies back into this browser."
            alert.addButton(withTitle: "Secure session")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                GoogleSignInCoordinator.shared.start(url: url)
            }
        }
    }

    private func note(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if let pending = tab?.httpsUpgradeURL {
            tab?.pageWarning = .httpsFailed(pending)
            tab?.httpsUpgradeURL = nil
            tab?.errorText = nil
            tab?.isLoading = false
            return
        }
        tab?.errorText = ns.localizedDescription
        tab?.isLoading = false
    }
}

enum SitePrompt {
    static func ask(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Block")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum PasswordPrompt {
    enum Result { case save, later, never }
    static func ask(host: String, username: String) -> Result {
        let alert = NSAlert()
        alert.messageText = "Save password for \(host)?"
        let account = username.isEmpty ? "No username was entered." : "Account: \(username)"
        alert.informativeText = "\(account)\nThe password is stored in the Keychain, not in a file."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Never for This Site")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .never
        default: return .later
        }
    }
}

final class GoogleSignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleSignInCoordinator()
    private var session: ASWebAuthenticationSession?
    private var sessionToken = 0

    func start(url: URL) {
        sessionToken += 1
        let token = sessionToken
        let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: "sathariels") { [weak self] callback, _ in
            if let callback, let session = SessionRegistry.shared.keySession {
                session.navigateFocused(to: callback)
            }
            DispatchQueue.main.async {
                guard let self, self.sessionToken == token else { return }
                self.session = nil
            }
        }
        auth.presentationContextProvider = self
        auth.prefersEphemeralWebBrowserSession = false
        session = auth
        auth.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? ASPresentationAnchor()
    }
}
