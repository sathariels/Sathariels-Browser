import AppKit
import Foundation
import ImageIO
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
    @Published var pinned = false
    @Published var groupID: UUID?
    @Published var errorText: String?
    @Published var googleBlocked = false
    @Published var passwordUsernames: [String] = []
    @Published var pageWarning: PageWarning?
    var httpBypass: [String] = []
    var threatBypass: [String] = []
    var httpsUpgradeURL: URL?
    @Published var jsonDocument: JSONDocument?
    @Published var viewport = ViewportMode()
    var lastMIME = ""

    private(set) var webView: WKWebView?
    var lastFocused = Date.distantPast
    var focusCount = 0
    var scrollRestore: (x: Double, y: Double, url: String)?
    var savedScroll: (x: Double, y: Double)?
    var stateFile: String?
    @Published var reader: ReaderPage?
    weak var session: BrowserSession?
    let delegate: TabWebDelegate
    private var observations: [NSKeyValueObservation] = []
    private var faviconLoad: BoundedDataLoad?
    private var jsonLoad: BoundedDataLoad?

    deinit {
        releaseWebView()
    }

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
        jsonLoad?.cancel()
        jsonLoad = nil
        pageWarning = nil
        url = newURL
        if title == "New Tab" || title.isEmpty {
            title = newURL.host ?? "New Tab"
        }
        errorText = nil
        googleBlocked = false
        passwordUsernames = []
        jsonDocument = nil
        lastFocused = Date()
        scrollRestore = nil
        savedScroll = nil
        reader = nil
        if webView == nil {
            wake()
        } else {
            lifecycle = .live
            webView?.load(URLRequest(url: newURL))
        }
    }

    func wake() {
        guard webView == nil, let session, !session.isShutDown else { return }
        ContentBlocker.shared.ensureLoaded()
        let host = url?.host
        let site = host.map { session.permissions.site(for: $0) }
        let configuration = WebKitFactory.configuration(
            dataStore: session.dataStore,
            processPool: session.processPool,
            site: site,
            ruleLists: ContentBlocker.shared.applicableLists(),
            capturePasswords: !session.isPrivate,
            pageGhost: SettingsStore.shared.pageFieldGhost && !session.isPrivate
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        install(view, capturePasswords: !session.isPrivate, pageGhost: SettingsStore.shared.pageFieldGhost && !session.isPrivate)
        if let data = SessionStateStore.read(stateFile) {
            view.interactionState = data
        } else if let url {
            view.load(URLRequest(url: url))
            if let savedScroll {
                scrollRestore = (savedScroll.x, savedScroll.y, url.absoluteString)
            }
        }
    }

    func captureInteractionState() {
        guard let data = SessionStateStore.data(from: webView?.interactionState) else { return }
        stateFile = SessionStateStore.write(id: id, data: data) ?? stateFile
    }

    func toggleReader() {
        if reader != nil {
            reader = nil
            return
        }
        guard let webView else { return }
        let world = WKContentWorld.world(name: "sathariels.reader")
        Task { @MainActor [weak self, weak webView] in
            guard let webView else { return }
            let result = try? await webView.evaluateJavaScript(ReaderScript.source, in: nil, contentWorld: world)
            self?.reader = ReaderScript.page(from: result)
        }
    }

    func adopt(_ view: WKWebView, capturePasswords: Bool, pageGhost: Bool) {
        install(view, capturePasswords: capturePasswords, pageGhost: pageGhost)
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() {
        errorText = nil
        if webView == nil { wake() } else { webView?.reload() }
    }
    func stop() { webView?.stopLoading() }

    func loadJSON(from url: URL) {
        self.url = url
        title = url.lastPathComponent
        jsonDocument = nil
        errorText = nil
        let store = session?.dataStore.httpCookieStore
        let start: ([HTTPCookie]) -> Void = { [weak self] cookies in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let matched = cookies.filter { cookie in
                guard let host = url.host?.lowercased() else { return false }
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            let headers = HTTPCookie.requestHeaderFields(with: matched)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.jsonLoad?.cancel()
                self.jsonLoad = BoundedDataLoad.start(request: request, cap: JSONSniffer.byteCap, requireSuccess: false) { [weak self] data in
                    guard let self else { return }
                    self.jsonLoad = nil
                    guard self.url == url else { return }
                    guard let data, let text = String(data: data, encoding: .utf8), let document = JSONDocument(raw: text) else {
                        self.errorText = "This JSON response is too large or not valid JSON."
                        return
                    }
                    self.jsonDocument = document
                    if self.webView?.canGoBack != true {
                        self.releaseWebView()
                        self.lifecycle = .suspended
                        self.memory = .suspended
                    }
                }
            }
        }
        if let store {
            store.getAllCookies(start)
        } else {
            start([])
        }
    }

    func showJSONAsPage() {
        guard let url else { return }
        jsonDocument = nil
        navigate(to: url)
    }

    func applyViewport(_ mode: ViewportMode) {
        let reload = mode.mobileUserAgent != viewport.mobileUserAgent
        viewport = mode
        webView?.customUserAgent = mode.mobileUserAgent ? SafariUserAgent.iPhone : SafariUserAgent.current
        if reload { webView?.reload() }
    }

    func copyReadableMarkdown() {
        guard let webView else { return }
        webView.evaluateJavaScript(PageScripts.readableMarkdown) { result, _ in
            let text = (result as? String) ?? ""
            guard !text.isEmpty else { return }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
        }
    }

    func capturingMedia() -> Bool {
        guard let webView else { return false }
        if #available(macOS 13.3, *) {
            return webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
        }
        return false
    }

    func restoreScroll(in webView: WKWebView) {
        guard let scrollRestore, let url = webView.url?.absoluteString, scrollRestore.url == url else { return }
        let x = scrollRestore.x
        let y = scrollRestore.y
        self.scrollRestore = nil
        savedScroll = (x, y)
        webView.evaluateJavaScript("window.scrollTo(\(x), \(y));", completionHandler: nil)
    }

    func suspend() {
        captureInteractionState()
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
        faviconLoad?.cancel()
        faviconLoad = nil
        jsonLoad?.cancel()
        jsonLoad = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let webView {
            WebKitFactory.detach(webView)
        }
        webView = nil
    }

    func insert(_ text: String, completion: @escaping (Bool) -> Void) {
        guard let webView else { completion(false); return }
        webView.callAsyncJavaScript(
            PageScripts.insertText,
            arguments: ["text": text],
            in: nil,
            in: .page,
            completionHandler: { result in
                completion((try? result.get()) as? Bool == true)
            }
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
        let fallbackTitle = title
        webView.evaluateJavaScript(PageScripts.pageContext) { [weak self] result, _ in
            let dict = result as? [String: Any]
            let pageTitle = (dict?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? self?.title ?? fallbackTitle
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

    func allowCurrentWarning() {
        guard let warning = pageWarning else { return }
        switch warning {
        case .httpsFailed(let url):
            remember(&httpBypass, url.absoluteString)
            httpsUpgradeURL = nil
            pageWarning = nil
            navigate(to: url)
        case .unsafe(let url):
            remember(&threatBypass, url.absoluteString)
            pageWarning = nil
            if webView == nil { wake() }
            webView?.load(URLRequest(url: url))
        }
    }

    private func remember(_ list: inout [String], _ value: String) {
        list.removeAll { $0 == value }
        list.append(value)
        if list.count > 32 { list.removeFirst(list.count - 32) }
    }

    func fillPassword(username: String) {
        guard let host = url?.host else { return }
        PasswordUnlock.authorize(host: host) { [weak self] ok in
            guard ok else { return }
            self?.fillPasswordUnlocked(username: username)
        }
    }

    private func fillPasswordUnlocked(username: String) {
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
            self.faviconLoad?.cancel()
            self.faviconLoad = BoundedDataLoad.start(request: request, cap: 47_999, requireSuccess: true) { [weak self] data in
                guard let self else { return }
                self.faviconLoad = nil
                guard let data, !data.isEmpty, let image = Self.faviconImage(data) else { return }
                self.favicon = image
            }
        }
    }

    private func install(_ view: WKWebView, capturePasswords: Bool, pageGhost: Bool) {
        if let existing = webView, existing !== view {
            releaseWebView()
        }
        WebKitFactory.attach(webView: view, handler: delegate, capturePasswords: capturePasswords, pageGhost: pageGhost)
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

    private static func faviconImage(_ data: Data) -> NSImage? {
        if let image = imageSourceThumbnail(data, maxPixel: 32) {
            return image
        }
        guard let image = NSImage(data: data) else { return nil }
        let pixels = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        if pixels > 0 && pixels <= 32 && max(image.size.width, image.size.height) <= 32 {
            return image
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return drawnThumbnail(image, side: 32)
    }

    private static func imageSourceThumbnail(_ data: Data, maxPixel: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
    }

    private static func drawnThumbnail(_ image: NSImage, side: CGFloat) -> NSImage? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(side / source.width, side / source.height)
        let target = NSSize(width: max(1, source.width * scale), height: max(1, source.height * scale))
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target), from: NSRect(origin: .zero, size: source), operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
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

/// Downloads a response body only up to `cap` bytes, then releases the session.
/// Callers cancel it when the tab closes so a large file cannot stay buffered.
final class BoundedDataLoad: NSObject, URLSessionDataDelegate {
    private let cap: Int
    private let requireSuccess: Bool
    private let completion: (Data?) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var settled = false

    @discardableResult
    static func start(request: URLRequest, cap: Int, requireSuccess: Bool, completion: @escaping (Data?) -> Void) -> BoundedDataLoad {
        let load = BoundedDataLoad(cap: cap, requireSuccess: requireSuccess, completion: completion)
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration, delegate: load, delegateQueue: nil)
        load.session = session
        let task = session.dataTask(with: request)
        load.task = task
        task.resume()
        return load
    }

    private init(cap: Int, requireSuccess: Bool, completion: @escaping (Data?) -> Void) {
        self.cap = cap
        self.requireSuccess = requireSuccess
        self.completion = completion
    }

    func cancel() {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        buffer.removeAll(keepingCapacity: false)
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if requireSuccess, let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(cap) {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let stop: URLSessionDataTask?
        if settled {
            stop = nil
        } else {
            let projected = buffer.count.addingReportingOverflow(data.count)
            if projected.overflow || projected.partialValue > cap {
                buffer.removeAll(keepingCapacity: false)
                stop = task
            } else {
                buffer.append(data)
                stop = nil
            }
        }
        lock.unlock()
        stop?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let payload = error == nil ? buffer : nil
        buffer.removeAll(keepingCapacity: false)
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            session?.finishTasksAndInvalidate()
        }
        DispatchQueue.main.async {
            self.completion(payload)
        }
    }
}
