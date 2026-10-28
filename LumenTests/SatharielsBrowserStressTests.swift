import AppKit
import Darwin
import SwiftUI
import XCTest
import WebKit
@testable import SatharielsBrowser

/// Drives the real session, WebKit, and library code. Prints `STRESS` lines for the workflow.
@MainActor
final class SatharielsBrowserStressTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 1500
    }

    func testHeavySitesAndSmartSleep() {
        let previous = SettingsStore.shared.tabSleepMode
        SettingsStore.shared.tabSleepMode = .off
        let session = BrowserSession(launch: WindowLaunch(index: -301, isPrivate: true))
        defer {
            SettingsStore.shared.tabSleepMode = previous
            session.shutdown()
        }
        let urls = Self.heavySites
        XCTAssertGreaterThanOrEqual(urls.count, 50)
        report("heavy", "baseline", status: "pass", sample: StressSample.take())
        var opened = 0
        for mark in [10, 25, 50] {
            while opened < mark {
                session.newTab(url: urls[opened])
                opened += 1
            }
            for tab in session.tabs { tab.lastFocused = Date() }
            pump(3)
            let live = session.tabs.filter { $0.webView != nil }.count
            report("heavy", "tabs\(mark)", status: "pass", sample: StressSample.take(), extra: [
                "live_webviews": "\(live)",
                "tabs": "\(session.tabs.count)",
            ])
            XCTAssertGreaterThanOrEqual(session.tabs.count, mark + 1)
        }
        let before = session.tabs.filter { $0.webView != nil }.count
        for tab in session.tabs where tab.id != session.focusedTab?.id {
            tab.lastFocused = Date().addingTimeInterval(-(31 * 60))
            tab.focusCount = 1
        }
        SettingsStore.shared.tabSleepMode = .smart
        session.suspendIdle()
        pump(8)
        let after = session.tabs.filter { $0.webView != nil }.count
        let slept = max(0, before - after)
        report("heavy", "after-sleep", status: slept > 0 ? "pass" : "fail", sample: StressSample.take(), extra: [
            "live_webviews": "\(after)",
            "slept": "\(slept)",
            "before": "\(before)",
        ])
        XCTAssertGreaterThan(slept, 0, "smart sleep should discard background tabs idle for 31 minutes")
    }

    func testOpenCloseLoopReturnsNearBaseline() {
        let session = BrowserSession(launch: WindowLaunch(index: -302, isPrivate: true))
        defer { session.shutdown() }
        let baseline = StressSample.take()
        report("leak", "baseline", status: "pass", sample: baseline)
        for index in 0..<200 {
            session.newTab(url: URL(string: "about:blank")!)
            let opened = session.focusedTab
            XCTAssertNotNil(opened?.webView)
            if let id = opened?.id, session.tabs.count > 1 {
                session.closeTab(id)
            }
            if index == 49 || index == 199 {
                pump(0.4)
                let sample = StressSample.take()
                let growth = sample.totalMB - baseline.totalMB
                report("leak", "after-\(index + 1)", status: growth < 150 ? "pass" : "fail", sample: sample, extra: [
                    "growth_mb": "\(growth)",
                    "live_webviews": "\(session.tabs.filter { $0.webView != nil }.count)",
                ])
            }
        }
        pump(1)
        let end = StressSample.take()
        let growth = end.totalMB - baseline.totalMB
        let live = session.tabs.filter { $0.webView != nil }.count
        report("leak", "final", status: growth < 150 && live <= 1 ? "pass" : "fail", sample: end, extra: [
            "growth_mb": "\(growth)",
            "live_webviews": "\(live)",
        ])
        XCTAssertLessThan(growth, 150)
        XCTAssertLessThanOrEqual(live, 1)
    }

    func testRapidPopupOpenClose() {
        SettingsStore.shared.tabSleepMode = .off
        let session = BrowserSession(launch: WindowLaunch(index: -303, isPrivate: false))
        defer {
            SettingsStore.shared.tabSleepMode = .smart
            session.shutdown()
        }
        session.permissions.set(host: "example.com", kind: .popups, choice: .allow)
        session.navigateFocused(to: URL(string: "about:blank")!)
        pump(0.5)
        let openerTab = session.focusedTab?.id
        let opener = session.focusedTab?.webView
        XCTAssertNotNil(opener)
        let handlersBefore = WebKitFactory.installedHandlerNames(for: opener!.configuration.userContentController)
        var opened = 0
        var lostAt = -1
        for index in 0..<100 {
            let script = "window.open('about:blank','stress\(index)','width=420,height=320');"
            opener?.evaluateJavaScript(script, completionHandler: nil)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline && session.popups.openCount == 0 {
                pump(0.05)
            }
            if session.popups.openCount > 0 { opened += 1 }
            session.popups.closeAll()
            let extras = session.tabs.map(\.id).filter { $0 != openerTab }
            for id in extras { session.closeTab(id) }
            let names = WebKitFactory.installedHandlerNames(for: opener!.configuration.userContentController)
            if names != handlersBefore {
                lostAt = index
                break
            }
        }
        let handlersAfter = WebKitFactory.installedHandlerNames(for: opener!.configuration.userContentController)
        let crashed = !Self.recentCrashReports().isEmpty
        let status = lostAt < 0 && !crashed && opened >= 90 ? "pass" : "fail"
        report("popup", "100", status: status, extra: [
            "opened": "\(opened)",
            "lost_at": "\(lostAt)",
            "handlers": handlersAfter.sorted().joined(separator: "|"),
            "opener_delegate": opener?.navigationDelegate == nil ? "nil" : "set",
            "crash_reports": crashed ? "1" : "0",
        ])
        XCTAssertEqual(lostAt, -1, "closing a popup removed the opener's script handlers")
        XCTAssertFalse(crashed)
        XCTAssertGreaterThanOrEqual(opened, 90, "sized window.open should keep succeeding without aborting")
        XCTAssertEqual(session.popups.openCount, 0)
    }

    func testSessionRestoreLoadsOnlyFocusedTab() {
        let urls = Array(Self.heavySites.prefix(50))
        let tabIDs = (0..<50).map { _ in UUID() }
        let snapshots = zip(tabIDs, urls).enumerated().map { index, pair in
            TabSnapshot(id: pair.0, url: pair.1.absoluteString, title: "Tab \(index)", colorIndex: index % 6)
        }
        let window = WindowSnapshot(
            index: 81,
            tabs: snapshots,
            primaryTabID: tabIDs[0],
            secondaryTabID: nil,
            focusedPane: .primary,
            splitFraction: 0.5,
            sidebarWidth: 248
        )
        SessionStore.shared.markLaunchComplete()
        SessionStore.shared.update(window)
        SessionStore.shared.saveNow()
        LaunchCoordinator.shared.load()
        let started = Date()
        let restored = BrowserSession(launch: WindowLaunch(index: 81, isPrivate: false))
        let launchMS = Int(Date().timeIntervalSince(started) * 1000)
        pump(2)
        let live = restored.tabs.filter { $0.webView != nil }.count
        let sample = StressSample.take()
        report("restore", "relaunch", status: restored.tabs.count == 50 && live == 1 ? "pass" : "fail", sample: sample, extra: [
            "launch_ms": "\(launchMS)",
            "tabs": "\(restored.tabs.count)",
            "live_webviews": "\(live)",
        ])
        XCTAssertEqual(restored.tabs.count, 50)
        XCTAssertEqual(live, 1)
        restored.shutdown()
        SessionStore.shared.remove(index: 81)
        SessionStore.shared.saveNow()
    }

    func testReadingModeScrollAndCancelledDownloads() {
        let session = BrowserSession(launch: WindowLaunch(index: -305, isPrivate: true))
        defer { session.shutdown() }
        session.navigateFocused(to: URL(string: "about:blank")!)
        pump(0.3)
        guard let webView = session.focusedTab?.webView, let tab = session.focusedTab else {
            report("reader", "setup", status: "fail")
            XCTFail("missing web view")
            return
        }
        let html = Self.imagePage
        let loaded = expectation(description: "reader page")
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/chapter"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        tab.toggleReader()
        pump(2)
        let blocks = tab.reader?.blocks.count ?? 0
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        if let page = tab.reader {
            window.contentView = NSHostingView(rootView: ReaderView(tab: tab, page: page))
            window.makeKeyAndOrderFront(nil)
        }
        pump(1)
        let before = StressSample.take()
        report("reader", "extracted", status: blocks >= 8 ? "pass" : "fail", sample: before, extra: ["blocks": "\(blocks)"])
        if let scroll = Self.findScrollView(window.contentView) {
            let height = scroll.documentView?.bounds.height ?? 0
            var y: CGFloat = 0
            while y < height {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                y += 700
                pump(0.15)
            }
        }
        pump(1.5)
        let afterScroll = StressSample.take()
        report("reader", "scrolled", status: "pass", sample: afterScroll, extra: ["blocks": "\(blocks)"])
        window.close()

        let files = [
            "https://proof.ovh.net/files/10Mb.dat",
            "https://proof.ovh.net/files/100Mb.dat",
            "https://ash-speed.hetzner.com/100MB.bin",
        ]
        var started = 0
        let group = DispatchGroup()
        for raw in files {
            guard let url = URL(string: raw) else { continue }
            group.enter()
            webView.startDownload(using: URLRequest(url: url)) { download in
                DispatchQueue.main.async {
                    DownloadController.shared.accept(download, tabID: tab.id)
                    started += 1
                    group.leave()
                }
            }
        }
        let wait = expectation(description: "downloads")
        group.notify(queue: .main) { wait.fulfill() }
        let result = XCTWaiter.wait(for: [wait], timeout: 15)
        pump(2)
        let active = DownloadController.shared.rows.filter { $0.state == .active }.map(\.id)
        for id in active { DownloadController.shared.cancel(id) }
        pump(1)
        let leftover = DownloadController.shared.rows.filter { $0.state == .active }.count
        let status = result == .completed && started == files.count && leftover == 0 ? "pass" : "fail"
        report("download", "cancel", status: status, extra: [
            "started": "\(started)",
            "cancelled": "\(active.count)",
            "leftover": "\(leftover)",
        ])
        XCTAssertEqual(started, files.count)
        XCTAssertEqual(leftover, 0)
    }

    func testCommandSearchLatencyWithTenThousandEntries() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("stress-history-\(UUID().uuidString).sqlite").path
        let db = LibraryDB(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let insertStarted = Date()
        for index in 0..<10_000 {
            let url = URL(string: "https://notes.example/\(index % 80)/item-\(index)")!
            db.recordHistory(url: url, title: "Note \(index) \(index % 17 == 0 ? "alpha" : "beta")")
        }
        let insertMS = Int(Date().timeIntervalSince(insertStarted) * 1000)
        var samples: [Double] = []
        let queries = ["alpha", "beta", "note 42", "item-9000", "missing-token", "notes.example"]
        for _ in 0..<20 {
            let query = queries[samples.count % queries.count]
            let started = Date()
            _ = db.searchHistory(query, limit: 20)
            _ = db.searchBookmarks(query, limit: 10)
            let hits = db.searchHistory(query, limit: 8)
            _ = CommandSearch.results(query: query, tabs: [], bookmarks: [], history: hits)
            samples.append(Date().timeIntervalSince(started) * 1000)
        }
        let sorted = samples.sorted()
        let p50 = Int(sorted[sorted.count / 2])
        let p95 = Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        let worst = Int(sorted.last ?? 0)
        report("search", "10k", status: p95 < 500 ? "pass" : "fail", extra: [
            "insert_ms": "\(insertMS)",
            "p50_ms": "\(p50)",
            "p95_ms": "\(p95)",
            "max_ms": "\(worst)",
        ])
        XCTAssertLessThan(p95, 500)
    }

    func testVideoPlaybackAndPictureInPictureToggles() {
        let session = BrowserSession(launch: WindowLaunch(index: -307, isPrivate: true))
        defer { session.shutdown() }
        session.navigateFocused(to: URL(string: "about:blank")!)
        pump(0.3)
        guard let webView = session.focusedTab?.webView, let tab = session.focusedTab else {
            XCTFail("missing web view")
            return
        }
        let html = """
        <html><body>
        <video id="clip" src="https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4" autoplay playsinline></video>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/video"))
        pump(4)
        var results: [String] = []
        for _ in 0..<20 {
            let done = expectation(description: "pip")
            webView.evaluateJavaScript(PageScripts.pictureInPicture) { value, _ in
                results.append(String(describing: value ?? "nil"))
                done.fulfill()
            }
            wait(for: [done], timeout: 3)
            tab.togglePlayback()
            pump(0.2)
        }
        let crashes = Self.recentCrashReports().count
        report("video", "pip-20", status: crashes == 0 ? "pass" : "fail", extra: [
            "results": results.prefix(5).joined(separator: ","),
            "unique": Set(results).sorted().joined(separator: "|"),
            "crash_reports": "\(crashes)",
        ])
        XCTAssertEqual(crashes, 0)
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func report(_ scenario: String, _ phase: String, status: String, sample: StressSample? = nil, extra: [String: String] = [:]) {
        var fields = extra
        if let sample {
            fields["app_mb"] = "\(sample.appMB)"
            fields["webkit_mb"] = "\(sample.webkitMB)"
            fields["total_mb"] = "\(sample.totalMB)"
        }
        let body = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
        let line = "STRESS scenario=\(scenario) phase=\(phase) \(body) status=\(status)"
        NSLog("%@", line)
        print(line)
        let path = ProcessInfo.processInfo.environment["STRESS_REPORT"] ?? "/tmp/sathariels-stress.txt"
        let url = URL(fileURLWithPath: path)
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: path), let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func findScrollView(_ view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = findScrollView(child) { return found }
        }
        return nil
    }

    private static func recentCrashReports() -> [String] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let cutoff = Date().addingTimeInterval(-30 * 60)
        return names.filter { name in
            guard name.contains("Sathariels") || name.contains("Sathariels Browser") else { return false }
            let url = root.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return modified >= cutoff
        }
    }

    private static let imagePage: String = {
        var parts = ["<html><body><h1>Chapter</h1>"]
        for index in 0..<36 {
            let id = 10 + index
            parts.append("<img src=\"https://picsum.photos/id/\(id)/900/1200\" width=\"700\" alt=\"page \(index)\">")
        }
        parts.append("</body></html>")
        return parts.joined()
    }()

    private static let heavySites: [URL] = {
        let raw = [
            "https://www.youtube.com/",
            "https://www.youtube.com/feed/explore",
            "https://accounts.google.com/ServiceLogin?service=mail",
            "https://accounts.google.com/signin/v2/identifier?service=mail",
            "https://www.instructure.com/canvas",
            "https://canvas.instructure.com/login/canvas",
            "https://github.com/",
            "https://github.com/explore",
            "https://github.com/topics/swift",
            "https://github.com/topics/webkit",
            "https://www.reddit.com/",
            "https://www.reddit.com/r/programming/",
            "https://www.reddit.com/r/apple/",
            "https://www.reddit.com/r/swift/",
            "https://asurascans.com/",
            "https://en.wikipedia.org/wiki/WebKit",
            "https://en.wikipedia.org/wiki/MacOS",
            "https://en.wikipedia.org/wiki/Safari_(web_browser)",
            "https://en.wikipedia.org/wiki/Wikipedia",
            "https://en.wikipedia.org/wiki/YouTube",
            "https://en.wikipedia.org/wiki/Gmail",
            "https://en.wikipedia.org/wiki/GitHub",
            "https://en.wikipedia.org/wiki/Reddit",
            "https://en.wikipedia.org/wiki/Canvas_(LMS)",
            "https://en.wikipedia.org/wiki/Comic",
            "https://www.bbc.com/news",
            "https://www.bbc.com/news/technology",
            "https://www.bbc.com/news/world",
            "https://apnews.com/",
            "https://www.reuters.com/",
            "https://www.npr.org/",
            "https://www.theguardian.com/international",
            "https://www.theguardian.com/technology",
            "https://news.ycombinator.com/",
            "https://en.wikipedia.org/wiki/Computer",
            "https://en.wikipedia.org/wiki/Internet",
            "https://en.wikipedia.org/wiki/Web_browser",
            "https://en.wikipedia.org/wiki/Memory_management",
            "https://en.wikipedia.org/wiki/Process_(computing)",
            "https://en.wikipedia.org/wiki/SQLite",
            "https://en.wikipedia.org/wiki/Swift_(programming_language)",
            "https://github.com/apple/swift",
            "https://github.com/WebKit/WebKit",
            "https://www.youtube.com/results?search_query=webkit",
            "https://www.reddit.com/r/hardware/",
            "https://en.wikipedia.org/wiki/ARM_architecture_family",
            "https://en.wikipedia.org/wiki/X86-64",
            "https://en.wikipedia.org/wiki/Linux",
            "https://en.wikipedia.org/wiki/Mac_App_Store",
            "https://news.ycombinator.com/newest",
        ]
        return raw.compactMap(URL.init(string:))
    }()
}

private struct StressTaskInfo {
    var virtualSize: UInt64 = 0
    var residentSize: UInt64 = 0
    var totalUser: UInt64 = 0
    var totalSystem: UInt64 = 0
    var threadsUser: UInt64 = 0
    var threadsSystem: UInt64 = 0
    var policy: Int32 = 0
    var faults: Int32 = 0
    var pageins: Int32 = 0
    var cowFaults: Int32 = 0
    var messagesSent: Int32 = 0
    var messagesReceived: Int32 = 0
    var syscallsMach: Int32 = 0
    var syscallsUnix: Int32 = 0
    var csw: Int32 = 0
    var threadNum: Int32 = 0
    var numRunning: Int32 = 0
    var priority: Int32 = 0
}

@_silgen_name("proc_listpids")
private func proc_listpids(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidinfo")
private func stressProcPidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_name")
private func stressProcName(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ buffersize: UInt32) -> Int32

struct StressSample {
    var appMB: Int
    var webkitMB: Int
    var totalMB: Int

    static func take() -> StressSample {
        let app = appResidentBytes()
        let webkit = webKitResidentBytes()
        let appMB = Int(app / 1_048_576)
        let webkitMB = Int(webkit / 1_048_576)
        return StressSample(appMB: appMB, webkitMB: webkitMB, totalMB: appMB + webkitMB)
    }

    /// WebContent processes are reparented to launchd, so they are not children of the app.
    private static func webKitResidentBytes() -> Int64 {
        let bytes = proc_listpids(1, 0, nil, 0)
        guard bytes > 0 else { return 0 }
        let count = Int(bytes) / MemoryLayout<Int32>.size
        var pids = [Int32](repeating: 0, count: count)
        let written = pids.withUnsafeMutableBytes { raw in
            proc_listpids(1, 0, raw.baseAddress, bytes)
        }
        let n = min(count, Int(written) / MemoryLayout<Int32>.size)
        var total: Int64 = 0
        for pid in pids.prefix(n) where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            guard stressProcName(pid, &name, UInt32(name.count)) > 0 else { continue }
            let lower = String(cString: name).lowercased()
            guard lower.contains("webcontent") || lower.contains("networking") || lower.contains("gpu") else { continue }
            guard let rss = stressResident(pid) else { continue }
            total += rss
        }
        return total
    }

    private static func stressResident(_ pid: Int32) -> Int64? {
        var info = StressTaskInfo()
        let size = Int32(MemoryLayout<StressTaskInfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                stressProcPidinfo(pid, 4, 0, raw, size)
            }
        }
        guard result > 0 else { return nil }
        return Int64(info.residentSize)
    }

    private static func appResidentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.resident_size)
    }
}
