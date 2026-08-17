import AppKit
import WebKit
import XCTest
@testable import MCV

@MainActor
final class SemanticRuntimeTests: XCTestCase {
    func testIntentAwareTabsClassifyByPurposeNotOnlyHost() {
        _ = NSApplication.shared
        let manager = TabManager()
        manager.newTab(url: URL(string: "https://github.com/example/browser"))
        manager.newTab(url: URL(string: "https://www.youtube.com/watch?v=test"))
        var report = ""

        AIBrowserEngine.shared.run("tabs", current: manager.current, tabs: manager.tabs,
            show: { report = $0 }, toast: { _ in })

        XCTAssertTrue(report.contains("MC Browser"))
        XCTAssertTrue(report.contains("Entertainment"))
    }

    func testPageDiagnosticsCaptureJavaScriptAndResourceErrors() async throws {
        _ = NSApplication.shared
        let manager = TabManager()
        let tab = manager.newTab(url: nil)
        tab.webView.loadHTMLString("<script>console.error('diagnostic-probe'); Promise.reject(new Error('promise-probe'))</script>", baseURL: nil)
        try await waitUntil { !tab.webView.isLoading && tab.webView.url != nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        let value = try await tab.webView.evaluateJavaScript("globalThis.__mcvDiagnostics")
        let diagnostics = value as? [[String: Any]] ?? []

        XCTAssertTrue(diagnostics.contains { ($0["message"] as? String)?.contains("diagnostic-probe") == true })
        XCTAssertTrue(diagnostics.contains { ($0["message"] as? String)?.contains("promise-probe") == true })
    }

    func testElementInspectorCapturesOnlyObservedDOMEvidence() async throws {
        _ = NSApplication.shared
        let manager = TabManager()
        let tab = manager.newTab(url: nil)
        tab.webView.loadHTMLString("<button id='checkout' style='padding: 7px'>Pay securely</button>", baseURL: nil)
        try await waitUntil { !tab.webView.isLoading && tab.webView.url != nil }

        AIBrowserEngine.shared.run("inspect", current: tab, tabs: manager.tabs,
            show: { _ in }, toast: { _ in })
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('#checkout').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}))")
        let captured = try await tab.webView.evaluateJavaScript("globalThis.__mcvInspectedElement") as? [String: Any]

        XCTAssertEqual(captured?["tag"] as? String, "button")
        XCTAssertEqual(captured?["text"] as? String, "Pay securely")
        XCTAssertTrue((captured?["path"] as? String)?.contains("#checkout") == true)
        XCTAssertNotNil(captured?["styles"] as? [String: Any])
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertTrue(predicate())
    }
}
