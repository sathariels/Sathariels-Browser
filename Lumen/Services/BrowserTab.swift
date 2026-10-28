import AppKit
import Foundation
import WebKit

final class BrowserTab: ObservableObject, Identifiable {
    enum Lifecycle {
        case empty
        case live
        case suspended
    }

    let id: UUID
    @Published var url: URL?
    @Published var title: String
    @Published var favicon: NSImage?
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var lifecycle: Lifecycle
    @Published var memory: TabMemory
    @Published var colorIndex: Int
    @Published var errorText: String?
    @Published var googleBlocked = false
    @Published var passwordUsernames: [String] = []

    private(set) var webView: WKWebView?
    var lastFocused = Date.distantPast
    weak var session: BrowserSession?
    let delegate: TabWebDelegate
    private var observations: [NSKeyValueObservation] = []
    private var faviconTask: URLSessionDataTask?

    init(id: UUID = UUID(), url: URL?, title: String, colorIndex: Int, session: BrowserSession?) {
        self.id = id
        self.url = url
        self.title = title
        self.colorIndex = colorIndex
        self.session = session
        let delegate = TabWebDelegate()
        self.delegate = delegate
        if url == nil {
            lifecycle = .empty
            memory = .empty
        } else {
            lifecycle = .suspended
            memory = .suspended
        }
        delegate.tab = self
        delegate.session = session
    }

    func navigate(to newURL: URL) {
        url = newURL
        if title == "New Tab" || title.isEmpty {
            title = newURL.host ?? "New Tab"
        }
        errorText = nil
        googleBlocked = false
        passwordUsernames = []
        lastFocused = Date()
        if webView == nil {
            wake()
        } else {
            lifecycle = .live
            webView?.load(URLRequest(url: newURL))
        }
    }

    func wake() {
        guard webView == nil, let session else { return }
        let host = url?.host
        let site = host.map { session.permissions.site(for: $0) }
        let configuration = WebKitFactory.configuration(
            dataStore: session.dataStore,
            processPool: session.processPool,
            site: site,
            ruleList: ContentBlocker.shared.ruleList,
            blockingEnabled: SettingsStore.shared.contentBlocking,
            capturePasswords: !session.isPrivate
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        install(view, capturePasswords: !session.isPrivate)
        if let url {
            view.load(URLRequest(url: url))
        }
    }

    func adopt(_ view: WKWebView, capturePasswords: Bool) {
        install(view, capturePasswords: capturePasswords)
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() {
        errorText = nil
        if webView == nil { wake() } else { webView?.reload() }
    }
    func stop() { webView?.stopLoading() }

    func suspend() {
        releaseWebView()
        isLoading = false
        progress = 0
        canGoBack = false
        canGoForward = false
        googleBlocked = false
        if url == nil {
            lifecycle = .empty
            memory = .empty
        } else {
            lifecycle = .suspended
            memory = .suspended
        }
    }

    func releaseWebView() {
        faviconTask?.cancel()
        faviconTask = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let webView {
            WebKitFactory.detach(webView)
        }
        webView = nil
    }

    func insert(_ text: String) {
        guard let webView else { return }
        webView.callAsyncJavaScript(
            PageScripts.insertText,
            arguments: ["text": text],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func runFind(query: String, reset: Bool, completion: @escaping (Int, Int) -> Void) {
        guard let webView else {
            completion(0, -1)
            return
        }
        let script = reset
            ? "window.__lumenFind && window.__lumenFind.run(\(Self.jsString(query)))"
            : "window.__lumenFind && window.__lumenFind.step(\(query == "prev" ? -1 : 1))"
        webView.evaluateJavaScript(script) { result, _ in
            let count = Self.dictInt(result, key: "count") ?? 0
            let index = Self.dictInt(result, key: "index") ?? -1
            completion(count, index)
        }
    }

    func clearFind() {
        webView?.evaluateJavaScript("window.__lumenFind && window.__lumenFind.clear()", completionHandler: nil)
    }

    func pageSnapshot(completion: @escaping (_ title: String, _ selection: String, _ text: String) -> Void) {
        guard let webView else {
            completion(title, "", "")
            return
        }
        webView.evaluateJavaScript(PageScripts.pageContext) { result, _ in
            let dict = result as? [String: Any]
            let pageTitle = (dict?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? self.title
            let selection = dict?["selection"] as? String ?? ""
            let text = dict?["text"] as? String ?? ""
            completion(pageTitle, selection, text)
        }
    }

    func refreshHeuristic() {
        guard let webView else { return }
        webView.evaluateJavaScript(PageScripts.memoryProbe) { [weak self] result, _ in
            let dict = result as? [String: Any]
            let transfer = Int64((dict?["transfer"] as? NSNumber)?.int64Value ?? 0)
            let nodes = (dict?["nodes"] as? NSNumber)?.intValue ?? 0
            self?.memory = TabMemory(bytes: MemoryEstimate.bytes(transfer: transfer, nodes: nodes), kind: .estimate)
        }
    }

    func fillPassword(username: String) {
        guard let host = url?.host, let webView else { return }
        guard let password = PasswordVault.password(host: host, username: username) else { return }
        webView.callAsyncJavaScript(
            PageScripts.fillLogin,
            arguments: ["username": username, "password": password],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func considerPasswordFill() {
        guard session?.isPrivate == false, let host = url?.host, let webView else {
            passwordUsernames = []
            return
        }
        if SettingsStore.shared.neverSavePasswords(for: host) {
            passwordUsernames = []
            return
        }
        webView.evaluateJavaScript(PageScripts.hasPasswordField) { [weak self] result, _ in
            guard let self else { return }
            let hasField = (result as? Bool) ?? (result as? NSNumber)?.boolValue ?? false
            guard hasField else {
                self.passwordUsernames = []
                return
            }
            let accounts = PasswordVault.accounts(for: host)
            self.passwordUsernames = accounts.map(\.username)
            if accounts.count == 1 {
                self.fillPassword(username: accounts[0].username)
            }
        }
    }

    func loadFavicon() {
        guard let webView else { return }
        webView.evaluateJavaScript(PageScripts.faviconHref) { [weak self] result, _ in
            guard let self, let href = result as? String, let iconURL = URL(string: href) else { return }
            var request = URLRequest(url: iconURL)
            request.timeoutInterval = 6
            self.faviconTask?.cancel()
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                guard let self, let data, data.count > 0, data.count < 48_000, let image = NSImage(data: data) else { return }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
                DispatchQueue.main.async { self.favicon = image }
            }
            self.faviconTask = task
            task.resume()
        }
    }

    private func install(_ view: WKWebView, capturePasswords: Bool) {
        WebKitFactory.attach(webView: view, handler: delegate, capturePasswords: capturePasswords)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        webView = view
        lifecycle = .live
        memory = .unknown
        lastFocused = Date()
        observe(view)
    }

    private func observe(_ view: WKWebView) {
        observations.forEach { $0.invalidate() }
        observations = [
            view.observe(\.title, options: .new) { [weak self] view, _ in
                if let title = view.title, !title.isEmpty { self?.title = title }
            },
            view.observe(\.url, options: .new) { [weak self] view, _ in
                if let url = view.url, url.absoluteString != "about:blank" {
                    self?.url = url
                }
            },
            view.observe(\.estimatedProgress, options: .new) { [weak self] view, _ in
                self?.progress = view.estimatedProgress
            },
            view.observe(\.isLoading, options: .new) { [weak self] view, _ in
                self?.isLoading = view.isLoading
            },
            view.observe(\.canGoBack, options: .new) { [weak self] view, _ in
                self?.canGoBack = view.canGoBack
            },
            view.observe(\.canGoForward, options: .new) { [weak self] view, _ in
                self?.canGoForward = view.canGoForward
            }
        ]
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }

    private static func dictInt(_ value: Any?, key: String) -> Int? {
        guard let dict = value as? [String: Any] else { return nil }
        if let number = dict[key] as? NSNumber { return number.intValue }
        if let int = dict[key] as? Int { return int }
        return nil
    }
}
