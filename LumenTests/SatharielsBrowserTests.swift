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

    func testAsuraHostsAreNotThreatListed() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "threat-hashes", withExtension: "bin"))
        let hashes = ThreatList.decode(try Data(contentsOf: url))
        for host in ["asurascans.com", "www.asurascans.com", "asuracomic.net", "www.asuracomic.net"] {
            XCTAssertFalse(hashes.contains(ThreatList.hash64(host)), host)
        }
    }
}
