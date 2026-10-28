import AppKit
import XCTest
import WebKit
@testable import SatharielsBrowser

final class SatharielsBrowserTests: XCTestCase {
    @MainActor
    func testBundledContentRulesCompile() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "blocker-rules", withExtension: "json"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let identifier = "sathariels.test.\(UUID().uuidString)"
        let rules = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source)
        XCTAssertNotNil(rules)
        try await store.removeContentRuleList(forIdentifier: identifier)
    }

    func testPasswordFillRequiresApprovedSecurePage() throws {
        let approved = try XCTUnwrap(URL(string: "https://example.com/login"))
        XCTAssertEqual(PasswordPage.host(approved), "example.com")
        XCTAssertTrue(PasswordPage.matches(approved, current: approved))
        for raw in ["http://example.com/login", "https://example.com:8443/login", "https://other.example/login", "https://example.com/changed", "https://user@example.com/login"] {
            XCTAssertFalse(PasswordPage.matches(approved, current: URL(string: raw)))
        }
        XCTAssertNil(PasswordPage.host(URL(string: "http://example.com")))
        XCTAssertNil(PasswordPage.host(URL(string: "https://example.com:8443")))
        XCTAssertNil(PasswordPage.host(URL(string: "https://user@example.com")))
        XCTAssertNil(PasswordPage.host(nil))
    }

    func testClearDownloadsPreservesRecoverableTransfers() {
        XCTAssertTrue(DownloadController.canClear(.finished))
        XCTAssertTrue(DownloadController.canClear(.cancelled))
        XCTAssertFalse(DownloadController.canClear(.active))
        XCTAssertFalse(DownloadController.canClear(.paused))
        XCTAssertFalse(DownloadController.canClear(.failed))
    }

    func testClipboardMigrationAndOriginalImage() throws {
        let item = ClipItem(id: UUID(), kind: .image, text: "Image", created: Date(), pinned: true,
                            thumbFile: "preview.jpg", imageFile: "original.tiff")
        let encoded = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(ClipItem.self, from: encoded), item)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "imageFile")
        let restored = try JSONDecoder().decode(ClipItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.imageFile)
        XCTAssertEqual(restored.thumbFile, "preview.jpg")
        XCTAssertTrue(restored.pinned)
    }

    @MainActor
    func testManyNewTabsAllocateNoWebViews() {
        let session = BrowserSession(launch: WindowLaunch(index: -100, isPrivate: true))
        defer { session.shutdown() }
        for _ in 0..<50 { session.newTab() }
        XCTAssertEqual(session.tabs.count, 51)
        XCTAssertTrue(session.tabs.allSatisfy { $0.webView == nil && $0.lifecycle == .empty })
        XCTAssertNil(session.chatStore, "AI must remain lazy until requested")
    }

    @MainActor
    func testShutdownDropsWebViewsAndRefusesNewOnes() {
        let session = BrowserSession(launch: WindowLaunch(index: -103, isPrivate: true))
        defer { if !session.isShutDown { session.shutdown() } }
        session.newTab(url: URL(string: "about:blank"))
        XCTAssertNotNil(session.focusedTab?.webView)
        let count = session.tabs.count
        session.shutdown()
        XCTAssertTrue(session.tabs.allSatisfy { $0.webView == nil })
        session.newTab(url: URL(string: "https://example.com"))
        session.navigateFocused(to: URL(string: "https://example.com")!)
        XCTAssertEqual(session.tabs.count, count)
        XCTAssertTrue(session.tabs.allSatisfy { $0.webView == nil })
    }

    @MainActor
    func testPinnedTabIsNotClosedByCommand() throws {
        let session = BrowserSession(launch: WindowLaunch(index: -104, isPrivate: true))
        defer { session.shutdown() }
        let id = try XCTUnwrap(session.focusedTab?.id)
        session.setPinned(id, true)
        session.closeTab(id)
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertTrue(session.tabs[0].pinned)
    }

    @MainActor
    func testSleepingTabReleasesWebViewAndWakesOnSelection() {
        let session = BrowserSession(launch: WindowLaunch(index: -101, isPrivate: true))
        defer { session.shutdown() }
        session.newTab(url: URL(string: "about:blank"))
        let tab = session.focusedTab!
        XCTAssertNotNil(tab.webView)
        tab.suspend()
        XCTAssertNil(tab.webView)
        XCTAssertEqual(tab.lifecycle, .suspended)
        session.select(tab.id)
        XCTAssertNotNil(tab.webView)
        session.newTab()
        session.closeTab(tab.id)
        XCTAssertNil(tab.webView)
    }

    @MainActor
    func testBackgroundTabBudgetProtectsEdits() async throws {
        // The four-tab budget belongs to Aggressive mode; Smart deliberately
        // keeps recently used tabs awake. Do not depend on the user's preference.
        let settings = SettingsStore.shared
        let previousMode = settings.tabSleepMode
        settings.tabSleepMode = .aggressive
        defer { settings.tabSleepMode = previousMode }
        let session = BrowserSession(launch: WindowLaunch(index: -102, isPrivate: true))
        defer { session.shutdown() }
        for _ in 0..<7 { session.newTab(url: URL(string: "about:blank")) }
        for _ in 0..<100 {
            if session.tabs.allSatisfy({ !$0.isLoading }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let protected = session.tabs.first(where: { $0.webView != nil })!
        try await protected.webView!.evaluateJavaScript("window.__lumenHasEdits = true")
        protected.lastFocused = .distantPast
        session.suspendIdle()
        for _ in 0..<50 {
            if session.tabs.filter({ $0.webView != nil }).count <= 5 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(protected.webView, "Edited pages must survive routine cleanup")
        XCTAssertNotNil(session.focusedTab?.webView)
        // One protected old tab can exceed the soft four-tab target.
        XCTAssertLessThanOrEqual(session.tabs.filter { $0.webView != nil }.count, 5)
        XCTAssertTrue(session.tabs.contains { $0.lifecycle == .suspended })
    }

    func testSearchVersusHost() {
        let search = AddressResolver.resolve("lumen browser", engine: .duckDuckGo)
        XCTAssertEqual(search?.host, "duckduckgo.com")
        let host = AddressResolver.resolve("asurascans.com", engine: .duckDuckGo)
        XCTAssertEqual(host?.absoluteString, "https://asurascans.com")
        let localhost = AddressResolver.resolve("localhost:3000", engine: .google)
        XCTAssertEqual(localhost?.absoluteString, "http://localhost:3000")
        XCTAssertNil(AddressResolver.resolve("   ", engine: .bing))
    }

    func testSearchPreservesReservedCharacters() {
        for engine in SearchEngine.allCases {
            let query = "C++ & Swift #examples? café"
            let url = engine.searchURL(for: query)!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, query)
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "udm" })?.value, engine == .googleAI ? "50" : nil)
            XCTAssertNil(components.fragment)
            XCTAssertTrue(url.absoluteString.contains("%2B%2B"))
        }
    }

    func testDevelopmentAddresses() {
        for input in ["localhost:5173/app", "127.0.0.1:8080/test", "[::1]:3000"] {
            XCTAssertEqual(AddressResolver.resolve(input, engine: .google)?.scheme, "http")
        }
        XCTAssertEqual(AddressResolver.resolve("example.com:8443/path?q=one", engine: .google)?.host, "example.com")
        XCTAssertEqual(AddressResolver.resolve("localhosting", engine: .google)?.host, "www.google.com")
        XCTAssertEqual(AddressResolver.resolve("https://localhost:3000", engine: .google)?.scheme, "https")
    }

    func testInlineCompletionPicksFrecency() {
        let now = Date()
        let entries = [
            Omnibox.Entry(urlString: "https://asus.com/", host: "asus.com", title: "ASUS", frecency: Omnibox.frecency(visitCount: 2, lastVisit: now.addingTimeInterval(-86_400 * 40), now: now), kind: .history, tabID: nil),
            Omnibox.Entry(urlString: "https://asurascans.com/comics", host: "asurascans.com", title: "Asura", frecency: Omnibox.frecency(visitCount: 12, lastVisit: now, now: now), kind: .history, tabID: nil)
        ]
        XCTAssertEqual(Omnibox.inlineHost(prefix: "asu", entries: entries), "asurascans.com")
        XCTAssertNil(Omnibox.inlineHost(prefix: "a", entries: entries))
        XCTAssertNil(Omnibox.inlineHost(prefix: "asurascans.com", entries: entries))
        XCTAssertEqual(Omnibox.completionSuffix(typed: "asu", suggestion: "asurascans.com"), "rascans.com")
        XCTAssertEqual(Omnibox.completionSuffix(typed: "ASU", suggestion: "asurascans.com"), "rascans.com")
    }

    func testSuggestionsIncludeSearch() {
        let entries = [
            Omnibox.Entry(urlString: "https://example.com/", host: "example.com", title: "Example", frecency: 4, kind: .history, tabID: nil)
        ]
        let rows = Omnibox.suggestions(prefix: "exam", entries: entries, engine: .duckDuckGo, limit: 8)
        XCTAssertEqual(rows.first?.kind, .history)
        XCTAssertEqual(rows.last?.kind, .search)
        XCTAssertTrue(rows.last?.title.contains("exam") == true)
    }

    func testFrecencyPrefersRecent() {
        let now = Date()
        let recent = Omnibox.frecency(visitCount: 2, lastVisit: now, now: now)
        let old = Omnibox.frecency(visitCount: 2, lastVisit: now.addingTimeInterval(-86_400 * 60), now: now)
        XCTAssertGreaterThan(recent, old)
    }

    func testKeywordShortcuts() {
        XCTAssertEqual(KeywordRouter.resolve("gh sathariels/lumen-browser", custom: [])?.absoluteString, "https://github.com/sathariels/lumen-browser")
        XCTAssertEqual(KeywordRouter.resolve("gh webkit browser", custom: [])?.host, "github.com")
        XCTAssertTrue(KeywordRouter.resolve("yt lofi", custom: [])?.absoluteString.contains("search_query=lofi") == true)
        XCTAssertEqual(KeywordRouter.resolve("lc two sum", custom: [])?.host, "leetcode.com")
        let custom = [KeywordShortcut(id: UUID(), keyword: "gh", template: "https://example.com/{query}")]
        XCTAssertEqual(KeywordRouter.resolve("gh hello", custom: custom)?.absoluteString, "https://example.com/hello")
        XCTAssertNil(KeywordRouter.resolve("example.com", custom: []))
    }

    func testJSONSniffer() {
        XCTAssertTrue(JSONSniffer.shouldIntercept(mime: "application/json", url: nil))
        XCTAssertTrue(JSONSniffer.shouldIntercept(mime: "text/plain", url: URL(string: "http://127.0.0.1:3000/data.json")))
        XCTAssertFalse(JSONSniffer.shouldIntercept(mime: "text/html", url: URL(string: "https://example.com/")))
        XCTAssertTrue(JSONSniffer.looksLikeJSON("  {\"a\":1}"))
        XCTAssertFalse(JSONSniffer.looksLikeJSON("<html>"))
        let value = JSONValue.parse(text: "{\"name\":\"ada\",\"n\":2}")
        if case .object(let pairs) = value {
            XCTAssertEqual(pairs.first?.key, "n")
        } else {
            XCTFail("expected object")
        }
    }

    func testAgentConfirmsRiskyClicksOnly() {
        XCTAssertTrue(AgentSafety.clickNeedsConfirm(type: "submit", text: "Pay now"))
        XCTAssertTrue(AgentSafety.clickNeedsConfirm(type: "button", text: "Send message"))
        XCTAssertFalse(AgentSafety.clickNeedsConfirm(type: "submit", text: "Search"))
        XCTAssertFalse(AgentSafety.clickNeedsConfirm(type: "button", text: "Next page"))
        XCTAssertTrue(AgentSafety.typeNeedsConfirm(type: "password", name: "", autocomplete: ""))
        XCTAssertTrue(AgentSafety.isPasswordField(type: "text", autocomplete: "current-password"))
        XCTAssertFalse(AgentSafety.typeNeedsConfirm(type: "text", name: "q", autocomplete: "off"))
    }

    func testGoogleRejectionDetection() {
        let blocked = URL(string: "https://accounts.google.com/v3/signin/rejected")!
        XCTAssertTrue(GoogleSignInDetector.isRejection(url: blocked))
        let ok = URL(string: "https://accounts.google.com/signin")!
        XCTAssertFalse(GoogleSignInDetector.isRejection(url: ok))
        XCTAssertTrue(GoogleSignInDetector.isRejection(url: ok, pageText: "This browser or app may not be secure"))
        let other = URL(string: "https://example.com/rejected")!
        XCTAssertFalse(GoogleSignInDetector.isRejection(url: other, pageText: "may not be secure"))
    }

    func testTrackingParametersAreRemoved() {
        let url = URL(string: "https://example.com/path?q=1&utm_source=ad&fbclid=abc&gclid=g&msclkid=m&mc_eid=e&igshid=i&keep=yes")!
        let stripped = TrackingStrip.stripped(url)
        XCTAssertEqual(stripped?.absoluteString, "https://example.com/path?q=1&keep=yes")
        XCTAssertNil(TrackingStrip.stripped(URL(string: "https://example.com/?q=1")!))
        XCTAssertTrue(TrackingStrip.isTracking("utm_campaign"))
        XCTAssertFalse(TrackingStrip.isTracking("q"))
    }

    func testHTTPSOnlySkipsLoopback() {
        XCTAssertTrue(HTTPSOnly.isExempt(host: "localhost"))
        XCTAssertTrue(HTTPSOnly.isExempt(host: "127.0.0.1"))
        XCTAssertFalse(HTTPSOnly.isExempt(host: "example.com"))
        let upgraded = HTTPSOnly.upgraded(URL(string: "http://example.com/a")!)
        XCTAssertEqual(upgraded?.absoluteString, "https://example.com/a")
        XCTAssertNil(HTTPSOnly.upgraded(URL(string: "http://localhost:3000/")!))
        XCTAssertNil(HTTPSOnly.upgraded(URL(string: "https://example.com/")!))
    }

    func testFilterLinesBecomeWebKitRules() {
        let blocked = FilterListCompiler.rules(from: "||doubleclick.net^")
        let trigger = blocked?["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["url-filter"] as? String, "^https?://([^/?#]*\\.)?doubleclick\\.net[:/?#]")
        XCTAssertEqual((blocked?["action"] as? [String: Any])?["type"] as? String, "block")
        XCTAssertNil(FilterListCompiler.rules(from: "||ads.example^$csp=script-src 'none'"))
        let cosmetic = FilterListCompiler.rules(from: "example.com##.ad-box")
        XCTAssertEqual((cosmetic?["action"] as? [String: Any])?["selector"] as? String, ".ad-box")
    }

    func testBundledBlockListFitsWebKitLimit() throws {
        let urls = try XCTUnwrap(Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil))
        let chunks = urls.filter { $0.lastPathComponent.hasPrefix("blocker-") }
        XCTAssertFalse(chunks.isEmpty)
        var total = 0
        for url in chunks {
            let data = try Data(contentsOf: url)
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
            XCTAssertLessThanOrEqual(rules.count, 150_000)
            total += rules.count
        }
        XCTAssertGreaterThan(total, 10_000)
    }

    func testThreatHashFindsBundledHost() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "threat-hashes", withExtension: "bin"))
        let hashes = ThreatList.decode(try Data(contentsOf: url))
        XCTAssertFalse(hashes.isEmpty)
        XCTAssertTrue(hashes.contains(ThreatList.hash64("02teste.cc")))
        XCTAssertFalse(hashes.contains(ThreatList.hash64("example.com")))
    }

    func testSessionRoundTrip() {
        let id = UUID()
        let snapshot = WindowSnapshot(
            index: 0,
            tabs: [TabSnapshot(id: id, url: "https://example.com/", title: "Example", colorIndex: 2)],
            primaryTabID: id,
            secondaryTabID: nil,
            focusedPane: .primary,
            splitFraction: 0.42,
            sidebarWidth: 260
        )
        let file = SessionFile(version: 1, windows: [snapshot])
        let data = try? JSONEncoder().encode(file)
        let decoded = data.flatMap { try? JSONDecoder().decode(SessionFile.self, from: $0) }
        XCTAssertEqual(decoded, file)
    }

    @MainActor
    func testAdoptedWindowReusesScriptHandlers() throws {
        let session = BrowserSession(launch: WindowLaunch(index: -211, isPrivate: false))
        defer { session.shutdown() }
        session.navigateFocused(to: URL(string: "about:blank")!)
        let opener = try XCTUnwrap(session.focusedTab?.webView)
        let controller = opener.configuration.userContentController
        let scripts = controller.userScripts.count
        XCTAssertGreaterThan(scripts, 0)
        XCTAssertTrue(WebKitFactory.installedHandlerNames(for: controller).contains("lumenPassword"))

        let popup = session.adoptExternalTab(configuration: opener.configuration)
        XCTAssertTrue(popup.configuration.userContentController === controller)
        XCTAssertEqual(controller.userScripts.count, scripts)
        XCTAssertTrue(WebKitFactory.installedHandlerNames(for: controller).contains("lumenPassword"))

        WebKitFactory.detach(popup)
        XCTAssertEqual(controller.userScripts.count, scripts)
        XCTAssertTrue(WebKitFactory.installedHandlerNames(for: controller).contains("lumenPassword"))

        _ = session.adoptExternalTab(configuration: opener.configuration)
        XCTAssertEqual(controller.userScripts.count, scripts)
    }

    @MainActor
    func testWindowOpenAndTargetBlankDoNotCrash() throws {
        SettingsStore.shared.tabSleepMode = .off
        let session = BrowserSession(launch: WindowLaunch(index: -210, isPrivate: false))
        defer {
            SettingsStore.shared.tabSleepMode = .smart
            session.shutdown()
        }
        session.permissions.set(host: "example.com", kind: .popups, choice: .allow)
        session.navigateFocused(to: URL(string: "about:blank")!)
        let opener = try XCTUnwrap(session.focusedTab?.webView)
        let script = """
        window.open("about:blank");
        window.open("about:blank", "sized", "width=480,height=640");
        var link = document.createElement("a");
        link.href = "about:blank";
        link.target = "_blank";
        document.body.appendChild(link);
        link.click();
        """
        opener.evaluateJavaScript(script, completionHandler: nil)
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if session.tabs.count >= 2 && session.popups.openCount >= 1 { break }
        }
        NSLog("POPUP_TEST tabs=\(session.tabs.count) popups=\(session.popups.openCount)")
        XCTAssertGreaterThanOrEqual(session.tabs.count, 2, "window.open() or target=_blank should add a tab")
        XCTAssertGreaterThanOrEqual(session.popups.openCount, 1, "a sized window.open should open a popup")
        let scripts = opener.configuration.userContentController.userScripts.count
        session.popups.closeAll()
        XCTAssertEqual(opener.configuration.userContentController.userScripts.count, scripts)
        XCTAssertTrue(WebKitFactory.installedHandlerNames(for: opener.configuration.userContentController).contains("lumenPassword"))
    }

    func testSmartSleepLeavesRecentTabsAlone() {
        let now = Date()
        let active = UUID()
        let neighbor = UUID()
        let recent = UUID()
        let old = UUID()
        let pinned = UUID()
        func input(_ id: UUID, focused: Date, count: Int, pinnedFlag: Bool = false, visible: Bool = false, neighborFlag: Bool = false) -> TabSleepInput {
            TabSleepInput(
                id: id, pinned: pinnedFlag, visible: visible, neighbor: neighborFlag,
                lastFocused: focused, focusCount: count, loading: false, downloading: false,
                capturing: false, hasWebView: true
            )
        }
        let tabs = [
            input(active, focused: now, count: 2, visible: true),
            input(neighbor, focused: now.addingTimeInterval(-3600), count: 1, neighborFlag: true),
            input(recent, focused: now.addingTimeInterval(-10 * 60), count: 1),
            input(old, focused: now.addingTimeInterval(-31 * 60), count: 1),
            input(pinned, focused: now.addingTimeInterval(-5 * 3600), count: 1, pinnedFlag: true),
        ]
        let quiet = TabSleepPolicy.candidates(tabs: tabs, mode: .smart, aggressiveMinutes: 2, pressure: false, critical: false, now: now)
        XCTAssertEqual(quiet, [old])
        let frequent = input(old, focused: now.addingTimeInterval(-31 * 60), count: 8)
        let kept = TabSleepPolicy.candidates(
            tabs: [input(active, focused: now, count: 1, visible: true), frequent],
            mode: .smart, aggressiveMinutes: 2, pressure: false, critical: false, now: now
        )
        XCTAssertTrue(kept.isEmpty)
        XCTAssertEqual(TabSleepPolicy.idleLimit(mode: .smart, aggressiveMinutes: 2, focusCount: 1), 30 * 60)
        XCTAssertGreaterThan(TabSleepPolicy.idleLimit(mode: .smart, aggressiveMinutes: 2, focusCount: 8), 30 * 60)
        let off = TabSleepPolicy.candidates(tabs: tabs, mode: .off, aggressiveMinutes: 2, pressure: false, critical: false, now: now)
        XCTAssertTrue(off.isEmpty)
        let pressed = TabSleepPolicy.candidates(tabs: tabs, mode: .smart, aggressiveMinutes: 2, pressure: true, critical: true, now: now)
        XCTAssertEqual(pressed, [old, recent])
        let aggressive = TabSleepPolicy.candidates(
            tabs: [input(active, focused: now, count: 1, visible: true), input(recent, focused: now.addingTimeInterval(-3 * 60), count: 1)],
            mode: .aggressive, aggressiveMinutes: 2, pressure: false, critical: false, now: now
        )
        XCTAssertEqual(aggressive, [recent])
    }

    func testReaderPrefersImageStripForChapters() {
        XCTAssertTrue(ReaderExtract.prefersImageStrip(imageCount: 12, textCharacters: 400))
        XCTAssertFalse(ReaderExtract.prefersImageStrip(imageCount: 2, textCharacters: 4000))
        let page = ReaderScript.page(from: [
            "title": "Chapter",
            "imageStrip": true,
            "blocks": [["kind": "image", "text": "https://example.com/1.jpg"], ["kind": "image", "text": "https://example.com/2.jpg"]],
        ] as [String: Any])
        XCTAssertEqual(page?.imageStrip, true)
        XCTAssertEqual(page?.blocks.count, 2)
    }

    func testDownloadListRoundTrip() throws {
        let record = DownloadRecord(
            id: UUID(), filename: DownloadController.safeFilename("a/b:file.bin"),
            destination: "/tmp/file.bin", source: "https://example.com/file.bin",
            bytesWritten: 10, bytesExpected: 20, state: .paused, detail: nil, hasResume: true
        )
        XCTAssertEqual(record.filename, "b-file.bin")
        let data = try JSONEncoder().encode([record])
        XCTAssertEqual(try JSONDecoder().decode([DownloadRecord].self, from: data), [record])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("page.cbz")
        try Data("a".utf8).write(to: first)
        let unique = DownloadController.uniqueURL(first)
        XCTAssertNotEqual(unique.lastPathComponent, "page.cbz")
    }

    func testUncleanExitIsDetected() {
        XCTAssertTrue(CrashCenter.interpret(state: "running"))
        XCTAssertFalse(CrashCenter.interpret(state: "clean"))
        XCTAssertFalse(CrashCenter.interpret(state: nil))
    }

    func testSessionKeepsScrollAndStateFile() throws {
        let id = UUID()
        let snapshot = TabSnapshot(
            id: id, url: "https://asurascans.com/", title: "Asura", colorIndex: 1,
            pinned: true, scrollX: 0, scrollY: 1400, stateFile: "states/\(id.uuidString).bin"
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)
        XCTAssertEqual(decoded.scrollY, 1400)
        XCTAssertEqual(decoded.stateFile, snapshot.stateFile)
        XCTAssertTrue(decoded.pinned)
        let legacy: [String: Any] = ["id": id.uuidString, "title": "Old", "colorIndex": 0, "pinned": false]
        let old = try JSONDecoder().decode(TabSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.scrollY)
        XCTAssertNil(old.stateFile)
    }

    func testUpdateVersionCompare() {
        XCTAssertTrue(VersionCompare.isNewer("v0.6.1", than: "0.6.0"))
        XCTAssertTrue(VersionCompare.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertFalse(VersionCompare.isNewer("0.6.0", than: "0.6.0"))
        XCTAssertFalse(VersionCompare.isNewer("0.6.0", than: "0.6.1"))
        XCTAssertTrue(VersionCompare.same("v0.6.1", "0.6.1"))
        XCTAssertFalse(UpdateSchedule.shouldQuery(last: Date(), now: Date(), manual: false))
        XCTAssertTrue(UpdateSchedule.shouldQuery(last: Date().addingTimeInterval(-90_000), now: Date(), manual: false))
        XCTAssertTrue(UpdateSchedule.shouldQuery(last: Date(), now: Date(), manual: true))
    }

    func testHomebrewCaskDetection() {
        XCTAssertTrue(HomebrewInstall.isCaskInstall { $0 == "/opt/homebrew/Caskroom/sathariels-browser" })
        XCTAssertTrue(HomebrewInstall.isCaskInstall { $0 == "/usr/local/Caskroom/sathariels-browser" })
        XCTAssertFalse(HomebrewInstall.isCaskInstall { _ in false })
        XCTAssertEqual(HomebrewInstall.brewExecutable { $0 == "/opt/homebrew/bin/brew" }, "/opt/homebrew/bin/brew")
        XCTAssertEqual(HomebrewInstall.brewExecutable { $0 == "/usr/local/bin/brew" }, "/usr/local/bin/brew")
        XCTAssertNil(HomebrewInstall.brewExecutable { _ in false })
    }

    func testReleaseChecksumMatchesFile() throws {
        let sums = "d28efb6293154213328429bb39b61f359b7ca312bdbe7061a4c06ca1eddf4923  Sathariels.Browser-macos.zip\n"
        XCTAssertEqual(ReleaseChecksum.parseSums(sums), "d28efb6293154213328429bb39b61f359b7ca312bdbe7061a4c06ca1eddf4923")
        let body = "SHA256 Sathariels.Browser-macos.zip abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\n"
        XCTAssertEqual(
            ReleaseChecksum.parseBody(body),
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("sathariels".utf8).write(to: file)
        let hash = try XCTUnwrap(ReleaseChecksum.sha256(file: file))
        XCTAssertTrue(ReleaseChecksum.matches(file: file, expected: hash))
        XCTAssertFalse(ReleaseChecksum.matches(file: file, expected: String(repeating: "ab", count: 32)))
    }

    func testAsuraHostsAreNotThreatListed() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "threat-hashes", withExtension: "bin"))
        let hashes = ThreatList.decode(try Data(contentsOf: url))
        for host in ["asurascans.com", "www.asurascans.com", "asuracomic.net", "www.asuracomic.net"] {
            XCTAssertFalse(hashes.contains(ThreatList.hash64(host)), host)
        }
    }

    func testLibrarySearchIndexesHistoryAndBookmarks() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString).sqlite").path
        let db = LibraryDB(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let page = try XCTUnwrap(URL(string: "https://example.com/docs/swift-search"))
        db.recordHistory(url: page, title: "Swift Search Guide")
        db.recordHistory(url: page, title: "Swift Search Guide")
        let found = db.searchHistory("swift", limit: 5)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].visitCount, 2)
        XCTAssertEqual(found[0].host, "example.com")
        XCTAssertTrue(db.searchHistory("missing-token", limit: 5).isEmpty)
        XCTAssertTrue(db.toggleBookmark(url: page, title: "Docs"))
        XCTAssertTrue(db.containsBookmark(url: page))
        XCTAssertEqual(db.searchBookmarks("docs", limit: 5).count, 1)
        XCTAssertFalse(db.toggleBookmark(url: page, title: "Docs"))
        XCTAssertFalse(db.containsBookmark(url: page))
        db.setZoom("example.com", 1.3)
        XCTAssertEqual(db.zoom(for: "Example.com") ?? 0, 1.3, accuracy: 0.001)
        db.clearZoom("example.com")
        XCTAssertNil(db.zoom(for: "example.com"))
        XCTAssertEqual(LibrarySearch.ftsQuery("Swift Search!"), "\"swift\"* \"search\"*")
    }

    func testCommandSearchCoversTabsBookmarksAndHistory() {
        let tab = UUID()
        let mark = Bookmark(id: UUID(), url: "https://example.com/saved", title: "Saved", host: "example.com", created: Date())
        let visit = HistoryEntry(id: UUID(), url: "https://example.com/old", title: "Old Page", host: "example.com", visitCount: 2, lastVisit: Date())
        let hits = CommandSearch.results(
            query: "old",
            tabs: [(tab, "Inbox", "https://mail.example/")],
            bookmarks: [mark],
            history: [visit]
        )
        XCTAssertEqual(hits.map(\.kind), [.history])
        let open = CommandSearch.results(query: "", tabs: [(tab, "Inbox", "")], bookmarks: [mark], history: [])
        XCTAssertEqual(open.first?.kind, .tab)
        XCTAssertTrue(open.contains { $0.kind == .bookmark })
    }

    func testFindZoomAndEnergyMath() {
        XCTAssertEqual(FindIndex.step(-1, count: 4, forward: true), 0)
        XCTAssertEqual(FindIndex.step(0, count: 4, forward: true), 1)
        XCTAssertEqual(FindIndex.step(0, count: 4, forward: false), 3)
        XCTAssertEqual(FindIndex.step(0, count: 0, forward: true), -1)
        XCTAssertEqual(SiteZoom.adjust(1, delta: 1), 1.1, accuracy: 0.001)
        XCTAssertEqual(SiteZoom.adjust(1, delta: -1), 0.9, accuracy: 0.001)
        XCTAssertEqual(SiteZoom.adjust(2.4, delta: 0), 1, accuracy: 0.001)
        XCTAssertEqual(SiteZoom.adjust(3, delta: 1), 3, accuracy: 0.001)
        XCTAssertEqual(EnergyEstimate.fraction(previous: 1_000_000_000, current: 1_500_000_000, seconds: 2), 0.25, accuracy: 0.001)
        XCTAssertEqual(EnergyEstimate.label(0.25), "med")
        XCTAssertFalse(PageScripts.mediaWatcher.contains("setInterval"))
        XCTAssertTrue(PageScripts.mediaWatcher.contains("play"))
        XCTAssertTrue(PageScripts.pictureInPicture.contains("requestPictureInPicture"))
        XCTAssertTrue(PageScripts.pictureInPicture.contains("webkitSetPresentationMode"))
        XCTAssertTrue(PageScripts.findCount("a").contains("return count"))
        XCTAssertFalse(PageScripts.findCount("a").contains("__lumenFind"))
    }

    func testTabLoadAssignsProcessesOnlyWhenCountsMatch() {
        let heavy = UUID()
        let light = UUID()
        let asleep = UUID()
        let tabs = [
            TabLoadInput(id: heavy, title: "Heavy", estimate: 80, asleep: false),
            TabLoadInput(id: light, title: "Light", estimate: 10, asleep: false),
            TabLoadInput(id: asleep, title: "Asleep", estimate: 0, asleep: true),
        ]
        let processes = [
            ProcessLoad(pid: 2, bytes: 20_000_000, cpu: 0.1),
            ProcessLoad(pid: 1, bytes: 90_000_000, cpu: 0.8),
        ]
        let matched = TabLoadAssign.rows(tabs: tabs, processes: processes)
        XCTAssertEqual(matched.map(\.id), [heavy, light, asleep])
        XCTAssertEqual(matched[0].bytes, 90_000_000)
        XCTAssertTrue(matched[0].measured)
        XCTAssertEqual(matched[0].cpu, 0.8, accuracy: 0.001)
        XCTAssertTrue(matched[2].asleep)
        let unmatched = TabLoadAssign.rows(tabs: tabs, processes: [processes[0]])
        XCTAssertFalse(unmatched.contains { $0.measured })
        XCTAssertEqual(unmatched.first { $0.id == heavy }?.bytes, 80)
    }
}
