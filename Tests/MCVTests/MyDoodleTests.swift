import XCTest
import WebKit
@testable import MCV

@MainActor
final class MyDoodleTests: XCTestCase {
    func testDoodleIsStrictlyScopedAndEventDriven() {
        let script = SecurityManager.myDoodleJS
        XCTAssertTrue(script.contains("host !== 'google.com'"))
        XCTAssertTrue(script.contains("host !== 'www.google.com'"))
        XCTAssertTrue(script.contains("location.pathname !== '/'"))
        XCTAssertTrue(script.contains("MutationObserver"))
        XCTAssertTrue(script.contains("observer.disconnect()"))
        XCTAssertFalse(script.contains("setInterval"))
        XCTAssertFalse(script.contains("setTimeout"))
    }

    func testDoodleActuallyReplacesGoogleLogoInsideWKWebView() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: SecurityManager.myDoodleJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString("<img class='lnXdpd' alt='Google'>", baseURL: URL(string: "https://www.google.com/"))
        try await Task.sleep(nanoseconds: 300_000_000)
        let text = try await webView.evaluateJavaScript("document.getElementById('mcv-mydoodle')?.textContent") as? String
        XCTAssertEqual(text, "MC Browser")
    }
}
