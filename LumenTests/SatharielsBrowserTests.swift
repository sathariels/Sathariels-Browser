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
}
