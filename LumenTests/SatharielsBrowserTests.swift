import XCTest
@testable import SatharielsBrowser

final class SatharielsBrowserTests: XCTestCase {
    func testSearchVersusHost() {
        let search = AddressResolver.resolve("lumen browser", engine: .duckDuckGo)
        XCTAssertEqual(search?.host, "duckduckgo.com")
        let host = AddressResolver.resolve("asurascans.com", engine: .duckDuckGo)
        XCTAssertEqual(host?.absoluteString, "https://asurascans.com")
        let localhost = AddressResolver.resolve("localhost:3000", engine: .google)
        XCTAssertEqual(localhost?.absoluteString, "https://localhost:3000")
        XCTAssertNil(AddressResolver.resolve("   ", engine: .bing))
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
